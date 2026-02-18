using Amazon.CDK;
using Amazon.CDK.AWS.Route53;
using Constructs;

namespace Infra
{
    public class DnsStackProps : StackProps
    {
        public string DomainName { get; init; } = "";
    }

    public class DnsStack : Stack
    {
        public IPublicHostedZone HostedZone { get; }

        public DnsStack(Construct scope, string id, DnsStackProps props) : base(scope, id, props)
        {
            HostedZone = new PublicHostedZone(this, "HostedZone", new PublicHostedZoneProps
            {
                ZoneName = props.DomainName
            });

            _ = new CfnOutput(this, "HostedZoneId", new CfnOutputProps
            {
                Value = HostedZone.HostedZoneId
            });

            _ = new CfnOutput(this, "HostedZoneNameServers", new CfnOutputProps
            {
                Value = Fn.Join(",", HostedZone.HostedZoneNameServers)
            });

        }
    }
}
