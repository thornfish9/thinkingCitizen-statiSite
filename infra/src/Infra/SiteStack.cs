using Amazon.CDK;
using Amazon.CDK.AWS.CertificateManager;
using Amazon.CDK.AWS.CloudFront;
using Amazon.CDK.AWS.CloudFront.Origins;
using Amazon.CDK.AWS.Route53;
using Amazon.CDK.AWS.Route53.Targets;
using Amazon.CDK.AWS.S3;
using Constructs;
using System;

namespace Infra
{
    public class SiteStackProps : StackProps
    {
        public string DomainName { get; init; } = "";
        public string CertArn { get; init; } = "";
    }

    public class SiteStack : Stack
    {
        public SiteStack(Construct scope, string id, SiteStackProps props) : base(scope, id, props)
        {
            // Lookup the hosted zone by name (no cross-stack construct passing)
            var zone = HostedZone.FromLookup(this, "HostedZoneLookup", new HostedZoneProviderProps
            {
                DomainName = props.DomainName
            });

            //cert ARN supplied via props (script/context bridge)
            var certArn = props.CertArn;
            ValidateCertArn(certArn);
            var cert = Certificate.FromCertificateArn(this, "SiteCert", certArn);

            // --- Content bucket (private, served via CloudFront OAC) ---
            var siteBucket = new Bucket(this, "SiteBucket", new BucketProps
            {
                BlockPublicAccess = BlockPublicAccess.BLOCK_ALL,
                Encryption = BucketEncryption.S3_MANAGED,

                // Safer while building. Switch to DESTROY for dev later if you want.
                RemovalPolicy = RemovalPolicy.RETAIN
            });

            var apexDistribution = new Distribution(this, "ApexDistribution", new DistributionProps
            {
                DefaultRootObject = "index.html",
                DomainNames = new[] { props.DomainName },
                Certificate = cert,
                MinimumProtocolVersion = SecurityPolicyProtocol.TLS_V1_2_2021,
                DefaultBehavior = new BehaviorOptions
                {
                    Origin = S3BucketOrigin.WithOriginAccessControl(siteBucket),
                    ViewerProtocolPolicy = ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                    Compress = true
                }
            });

            // --- WWW redirect bucket (S3 website redirect) ---
            var wwwBucket = new Bucket(this, "WwwRedirectBucket", new BucketProps
            {
                WebsiteRedirect = new RedirectTarget
                {
                    HostName = props.DomainName,
                    Protocol = RedirectProtocol.HTTPS
                },

                // S3 website endpoints require public access for redirect responses.
                PublicReadAccess = true,
                BlockPublicAccess = new BlockPublicAccess(new BlockPublicAccessOptions
                {
                    BlockPublicAcls = false,
                    BlockPublicPolicy = false,
                    IgnorePublicAcls = false,
                    RestrictPublicBuckets = false
                }),

                RemovalPolicy = RemovalPolicy.RETAIN
            });

            var wwwDistribution = new Distribution(this, "WwwDistribution", new DistributionProps
            {
                DomainNames = new[] { $"www.{props.DomainName}" },
                Certificate = cert,
                MinimumProtocolVersion = SecurityPolicyProtocol.TLS_V1_2_2021,
                DefaultBehavior = new BehaviorOptions
                {
                    Origin = new HttpOrigin(wwwBucket.BucketWebsiteDomainName, new HttpOriginProps
                    {
                        ProtocolPolicy = OriginProtocolPolicy.HTTP_ONLY
                    }),
                    ViewerProtocolPolicy = ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
                    Compress = true
                }
            });

            // --- Route53 records (A + AAAA) ---
            _ = new ARecord(this, "ApexARecord", new ARecordProps
            {
                Zone = zone,
                RecordName = props.DomainName,
                Target = RecordTarget.FromAlias(new CloudFrontTarget(apexDistribution))
            });

            _ = new AaaaRecord(this, "ApexAAAARecord", new AaaaRecordProps
            {
                Zone = zone,
                RecordName = props.DomainName,
                Target = RecordTarget.FromAlias(new CloudFrontTarget(apexDistribution))
            });

            _ = new ARecord(this, "WwwARecord", new ARecordProps
            {
                Zone = zone,
                RecordName = $"www.{props.DomainName}",
                Target = RecordTarget.FromAlias(new CloudFrontTarget(wwwDistribution))
            });

            _ = new AaaaRecord(this, "WwwAAAARecord", new AaaaRecordProps
            {
                Zone = zone,
                RecordName = $"www.{props.DomainName}",
                Target = RecordTarget.FromAlias(new CloudFrontTarget(wwwDistribution))
            });

            _ = new CfnOutput(this, "SiteBucketName", new CfnOutputProps
            {
                Value = siteBucket.BucketName
            });

            _ = new CfnOutput(this, "ApexDistributionDomainName", new CfnOutputProps
            {
                Value = apexDistribution.DistributionDomainName
            });

            _ = new CfnOutput(this, "WwwDistributionDomainName", new CfnOutputProps
            {
                Value = wwwDistribution.DistributionDomainName
            });
        }

        private void ValidateCertArn(string certArn)
        {
            var isOk = false;
            var msg = string.Empty;

            if (string.IsNullOrEmpty(certArn))
            {
                msg = "Arn must not be empty or null";
            }
            else if (!certArn.StartsWith("arn:"))
            {
                msg = @"Arn must begin with ""arn:"". Have [$certArn]";
            }
            else if (!certArn.Contains(":acm:us-east-1:")){
                msg = @"Cert ARN must contain "":acm:us-east-1:"", signifying AWS Certificate Manager Service in Region us-east-1. Have [$certArn]";
            }
            else if (!certArn.Contains(":certificate/"))
            {
                msg = @"Cert ARN must contain "":certificate/"", signifying ARN is for a certificate. Have [$certArn]";
            }
            else
            {
                isOk = true;
            }

            if (!isOk) {
                throw new ArgumentException(msg);
            };
        }
    }
}
