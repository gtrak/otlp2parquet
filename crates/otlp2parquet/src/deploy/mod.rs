//! Create command - generates platform-specific deployment configs
//!
//! Usage: `otlp2parquet create cloudflare` or `otlp2parquet create cf`
//!        `otlp2parquet create aws`

mod names;

pub mod aws;
pub mod cloudflare;

use clap::Subcommand;

#[derive(Subcommand)]
pub enum DeployCommand {
    /// Generate wrangler.toml for Cloudflare Workers + R2
    #[command(alias = "cf")]
    Cloudflare(cloudflare::CloudflareArgs),
    /// Generate template.yaml for AWS Lambda + S3/S3 Tables
    Aws(aws::AwsArgs),
}

impl DeployCommand {
    pub fn run(self) -> anyhow::Result<()> {
        match self {
            DeployCommand::Cloudflare(args) => cloudflare::run(args),
            DeployCommand::Aws(args) => aws::run(args),
        }
    }
}
