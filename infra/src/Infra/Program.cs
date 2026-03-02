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

            _ = new CertStack(app, "ThinkingCitizen-Cert", new CertStackProps
            {
                DomainName = domainName,
                Env = envEast
            });

            // We only instantiate SiteStack if certArn is available
            var certArn = app.Node.TryGetContext("certArn")?.ToString();

            // NOTE: SiteStack is only instantiated when certArn is provided via CDK context.
            // This is intentional.
            //
            // Without certArn, we skip creating SiteStack so DNS and Cert stacks can be
            // deployed independently (e.g., first-time bootstrap or partial rebuilds).
            //
            // Consequence:
            // If someone runs `cdk deploy ThinkingCitizen-Site` without passing
            //   -c certArn=...
            // the stack will not exist in the synthesized app and CDK will report
            // "stack not found" (because it was never instantiated).
            //
            // The canonical way to deploy Site is via the rebuild script, which:
            // 1. Deploys DNS + Cert
            // 2. Extracts the us-east-1 ACM cert ARN
            // 3. Re-invokes CDK with -c certArn=...
            if (!string.IsNullOrWhiteSpace(certArn))
            {
                _ = new SiteStack(app, "ThinkingCitizen-Site", new SiteStackProps
                {
                    DomainName = domainName,
                    CertArn = certArn,
                    Env = envWest
                });
            }

            app.Synth();
        }
    }
}
