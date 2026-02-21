AWS CDK Model Refresher (C#) — One-Year Memory Jogger

Purpose
This document explains the mental model of AWS CDK as used in this project. It focuses on how CDK actually works under the hood, what bootstrap does, how synth/deploy flow works, and how multi-account usage behaves. The goal is fast re-orientation after a long break.

---

## Big Picture: What CDK Actually Is

CDK is NOT a deployment engine.
CDK is a CloudFormation template generator written in a real programming language.

Mental model:
Your code → CDK construct tree → CloudFormation templates → AWS deploys those templates

So CDK is primarily:
A compiler from infrastructure code to CloudFormation JSON.

CloudFormation still does the actual provisioning.

---

## Core CDK Flow (End-to-End)

1. You run a CLI command
   Example:
   cdk synth
   cdk deploy

2. CDK CLI launches your app
   It reads cdk.json and executes the command in "app".
   For C# projects this is typically:
   dotnet run --project src/Infra/Infra.csproj

3. Your C# Program.Main runs
   This builds a construct tree in memory.

4. app.Synth() is called
   CDK converts the construct tree into a Cloud Assembly:

   * CloudFormation templates
   * metadata
   * assets

5. CLI consumes the output

   * cdk synth → prints templates
   * cdk deploy → sends templates to CloudFormation

---

## What Program.cs Really Does

Program.cs is the entry point of the CDK app.
It does three jobs:

1. Create the CDK App root
   var app = new App();

2. Instantiate stacks
   new DnsStack(app, ...)
   new SiteStack(app, ...)

3. Call app.Synth()
   This emits the CloudFormation templates.

Important: Nothing is deployed during execution of your C# code.
You are only building a model of infrastructure.

---

## Where Configuration Comes From (Context)

CDK uses a concept called context for runtime configuration.

Example:
cdk synth -c domainName=thinkingcitizen.org

Inside code:
var domainName = app.Node.TryGetContext("domainName");

Key ideas:

* "domainName" is a lookup key
* thinkingcitizen.org is the value

Sources of context (priority order):

1. CLI -c key=value
2. cdk.json "context" block
3. cached lookups (cdk.context.json)

Context is resolved BEFORE your stacks are created.

---

## What "Environment" Means in CDK

Each stack targets an AWS account + region.
This is called the stack Environment (Env).

Typical code:
var env = new Amazon.CDK.Environment
{
Account = Environment.GetEnvironmentVariable("CDK_DEFAULT_ACCOUNT"),
Region  = Environment.GetEnvironmentVariable("CDK_DEFAULT_REGION")
};

Where those values come from:
They are set by the CDK CLI based on the AWS profile used.

So this command:
cdk deploy --profile ops

Results in:
CDK_DEFAULT_ACCOUNT = ops account ID
CDK_DEFAULT_REGION  = profile region

Your code is just reading what the CLI already resolved.

---

## Multi-Account Mental Model

The CLI controls the target account.
NOT your code (unless you hard-code it).

Control mechanisms:

1. --profile flag
   cdk deploy --profile ops

2. AWS_PROFILE env var
   $env:AWS_PROFILE="ops"

3. Hard-pinned Env in code (optional safety)
   Account = "123456789012"

Best practice:
Use profiles to control account selection.
Pin account IDs only when you want hard safety rails.

---

## What Bootstrap Is (Critical Concept)

Bootstrap prepares an account/region for CDK deployments.
It installs infrastructure CDK needs to operate.

Bootstrap creates:

* An S3 bucket (asset staging)
* ECR repos (for container assets)
* IAM roles used during deployment
* CloudFormation execution roles

Think of bootstrap as:
Installing the CDK runtime into an AWS environment.

Without bootstrap, deploy will fail with role/bucket errors.

---

## When You Need to Bootstrap

You bootstrap ONCE per account/region pair.

Examples:
cdk bootstrap --profile ops
cdk bootstrap aws://123456789012/us-west-2

If you use multiple accounts:
You must bootstrap each one.

Admin account bootstrap ≠ Ops account bootstrap
They are independent environments.

---

## Bootstrap and Security Model

Modern CDK bootstrap installs multiple IAM roles:

Key ones:

* File publishing role
* CloudFormation execution role
* Lookup role

These roles enable:

* Asset uploads
* Cross-account deployments
* Least privilege execution

If deploy fails with role errors:
Bootstrap mismatch is often the cause.

---

## cdk synth vs cdk deploy

cdk synth

* Runs your program
* Produces templates
* No AWS changes

cdk deploy

* Runs synth first
* Sends templates to CloudFormation
* CloudFormation applies changes

Important:
Synth is pure and safe.
Deploy is side-effecting.

---

## Where the Templates Go

Synth produces a directory called:
cdk.out/

This contains:

* CloudFormation JSON
* asset manifests
* metadata

You can inspect templates here for debugging.

---

## Common Debugging Techniques

1. Verify target account
   aws sts get-caller-identity --profile ops

2. Print env inside Program.cs (temporary)
   Console.WriteLine(env.Account);

3. Inspect cdk.out templates
   Confirm domain names, regions, etc.

4. Use cdk diff
   Shows changes before deploy.

---

## Typical Failure Modes

Wrong account deployed
Cause: wrong AWS profile
Fix: verify sts identity before deploy

Missing bootstrap resources
Cause: deploying to new account
Fix: run cdk bootstrap

Context confusion
Cause: stale cdk.context.json
Fix: delete file and re-synth

Cross-region certificate issues
Cause: ACM for CloudFront must be us-east-1
Fix: separate cert stack in us-east-1

---

## Project-Specific Mental Notes

This project uses:

* Multiple stacks (DNS, Cert, Site)
* Possibly multiple regions
* Profile-based deployment

Implications:

* Bootstrap must exist in each target account/region
* Certificates for CloudFront must live in us-east-1
* Route53 is global but stack region still matters

---

## One-Minute Mental Reboot (Future You Read This First)

CDK is a compiler to CloudFormation.
cdk.json tells CDK how to run your program.
Program.cs builds stacks and calls Synth().
The CLI decides the AWS account via profile.
Bootstrap installs the CDK runtime into an account.
Synth is safe. Deploy makes changes.

If something is broken:
Check profile → check bootstrap → check region → check context.

---

### cdk doctor — what it is and when to use it

`cdk doctor` is a read-only diagnostic command that verifies your local AWS CDK environment is wired correctly. It inspects your Node runtime, CDK CLI install, and basic AWS configuration (like profiles and regions) to catch common setup problems such as incompatible Node versions, broken npm installs, or missing AWS tooling. It does not modify your system or make any AWS calls — it’s purely a sanity check.

Run `cdk doctor` any time you’re setting up a new machine, after upgrading Node or CDK, or when CDK behaves unexpectedly (for example, synth or deploy errors that don’t make sense). It’s especially useful early in a project to confirm your toolchain is healthy before debugging infrastructure code.

---

## End of refresher
