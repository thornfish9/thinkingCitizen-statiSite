using Amazon.CDK;
using Amazon.CDK.AWS.CertificateManager;
using Amazon.CDK.AWS.Route53;
using Amazon.CDK.AWS.SSM;
using Constructs;

namespace Infra
{
    public class CertStackProps : StackProps
    {
        public string DomainName { get; init; } = "";
    }

    public class CertStack : Stack
    {
        public string CertArnParamName { get; }

        public CertStack(Construct scope, string id, CertStackProps props) : base(scope, id, props)
        {
            // Hosted zone must already exist (created by DnsStack)
            var zone = HostedZone.FromLookup(this, "HostedZoneLookup", new HostedZoneProviderProps
            {
                DomainName = props.DomainName
            });

            // Cert must be created in us-east-1 (stack Env must be us-east-1)
            var cert = new Certificate(this, "SiteCert", new CertificateProps
            {
                DomainName = props.DomainName,
                SubjectAlternativeNames = new[] { $"www.{props.DomainName}" },
                Validation = CertificateValidation.FromDns(zone)
            });

            // Write cert ARN to SSM so SiteStack (in another region) can read it
            CertArnParamName = $"/thinkingcitizen/{props.DomainName}/cloudfront-cert-arn";

            _ = new StringParameter(this, "CloudFrontCertArnParam", new StringParameterProps
            {
                ParameterName = CertArnParamName,
                StringValue = cert.CertificateArn
            });

            _ = new CfnOutput(this, "CertificateArn", new CfnOutputProps
            {
                Value = cert.CertificateArn
            });

            _ = new CfnOutput(this, "CertArnParamName", new CfnOutputProps
            {
                Value = CertArnParamName
            });
        }
    }
}
