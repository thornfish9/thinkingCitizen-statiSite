using Amazon.CDK;
using System;

namespace Infra
{
    public class Program
    {
        public static void Main(string[] args)
        {
            var app = new App();

            var domainName = app.Node.TryGetContext("domainName")?.ToString();

            if (string.IsNullOrWhiteSpace(domainName))
            {
                throw new Exception("Missing required context: domainName. Set it in cdk.json context or use: cdk synth -c domainName=example.com");
            }

            var account = System.Environment.GetEnvironmentVariable("CDK_DEFAULT_ACCOUNT");
            var region = System.Environment.GetEnvironmentVariable("CDK_DEFAULT_REGION");

            if (string.IsNullOrWhiteSpace(account) || string.IsNullOrWhiteSpace(region))
            {
                throw new Exception("CDK_DEFAULT_ACCOUNT or CDK_DEFAULT_REGION not set. Run via `cdk ... --profile citizen-deploy`.");
            }

            var envWest = new Amazon.CDK.Environment
            {
                Account = account,
                Region = region
            };

            var envEast = new Amazon.CDK.Environment
            {
                Account = account,
                Region = "us-east-1"
            };

            // DNS stack (Route53 hosted zone)
            _ = new DnsStack(app, "ThinkingCitizen-Dns", new DnsStackProps
            {
                DomainName = domainName,
                Env = envWest
            });

            // Cert stack (ACM in us-east-1) writes ARN to SSM
            _ = new CertStack(app, "ThinkingCitizen-Cert", new CertStackProps
            {
                DomainName = domainName,
                Env = envEast
            });

            // Site stack reads cert ARN from SSM (no cross-region references)
            _ = new SiteStack(app, "ThinkingCitizen-Site", new SiteStackProps
            {
                DomainName = domainName,
                CertificateArnSsmParamName = $"/thinkingcitizen/{domainName}/cloudfront-cert-arn",
                Env = envWest
            });

            app.Synth();
        }
    }
}
