resource "random_id" "suffix" { byte_length = 3 }

module "primary" {
  source            = "./modules/three_tier"
  name_prefix       = "${var.project_name}-${var.env}-primary"
  region            = var.primary_region
  vpc_cidr          = var.primary_vpc_cidr
  azs               = var.primary_azs
  code_bucket_name  = "${var.code_bucket_prefix}-${var.env}-${var.primary_region}-${random_id.suffix.hex}"
  web_instance_type = var.web_instance_type
  app_instance_type = var.app_instance_type
  web_desired       = var.web_desired
  app_desired       = var.app_desired
  web_user_data     = file("${path.module}/user_data/web.sh")
  app_user_data     = file("${path.module}/user_data/app.sh")
}

module "secondary" {
  source            = "./modules/three_tier"
  providers         = { aws = aws.secondary }
  name_prefix       = "${var.project_name}-${var.env}-secondary"
  region            = var.secondary_region
  vpc_cidr          = var.secondary_vpc_cidr
  azs               = var.secondary_azs
  code_bucket_name  = "${var.code_bucket_prefix}-${var.env}-${var.secondary_region}-${random_id.suffix.hex}"
  web_instance_type = var.web_instance_type
  app_instance_type = var.app_instance_type
  web_desired       = var.web_desired
  app_desired       = var.app_desired
  web_user_data     = file("${path.module}/user_data/web.sh")
  app_user_data     = file("${path.module}/user_data/app.sh")
}

# DB subnet groups (root)
resource "aws_db_subnet_group" "primary" {
  name       = "${var.project_name}-${var.env}-db-subnets-primary"
  subnet_ids = module.primary.db_subnet_ids
}
resource "aws_db_subnet_group" "secondary" {
  provider   = aws.secondary
  name       = "${var.project_name}-${var.env}-db-subnets-secondary"
  subnet_ids = module.secondary.db_subnet_ids
}

# Primary writer
resource "aws_db_instance" "primary" {
  identifier              = "${var.project_name}-${var.env}-mysql"
  engine                  = "mysql"
  engine_version          = var.db_engine_version
  instance_class          = var.db_instance_class
  username                = var.db_username
  password                = var.db_password
  allocated_storage       = 20
  max_allocated_storage   = 100
  multi_az                = true
  backup_retention_period = 1
  db_subnet_group_name    = aws_db_subnet_group.primary.name
  vpc_security_group_ids  = [module.primary.db_sg_id]
  skip_final_snapshot     = true
  deletion_protection     = false
}

# Cross-region read replica
resource "aws_db_instance" "secondary_replica" {
  provider               = aws.secondary
  identifier             = "${var.project_name}-${var.env}-mysql-replica"
  engine                 = "mysql"
  instance_class         = var.db_instance_class
  replicate_source_db    = aws_db_instance.primary.arn
  db_subnet_group_name   = aws_db_subnet_group.secondary.name
  vpc_security_group_ids = [module.secondary.db_sg_id]
  publicly_accessible    = false
  apply_immediately      = true
  skip_final_snapshot    = true
  deletion_protection    = false
  depends_on             = [aws_db_instance.primary]
}

# S3 CRR, SNS, Alarms, Route53 (same as previous fixed version)
# (omitted here for brevity in this cell; appended below)

# ---------------- S3 Cross-Region Replication (bi-directional) ----------------
resource "aws_s3_bucket_versioning" "primary" {
  bucket = module.primary.code_bucket
  versioning_configuration { status = "Enabled" }
}
resource "aws_s3_bucket_versioning" "secondary" {
  provider = aws.secondary
  bucket   = module.secondary.code_bucket
  versioning_configuration { status = "Enabled" }
}
data "aws_iam_policy_document" "replication_trust_primary" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "replication_primary_to_secondary" {
  name               = "${var.project_name}-${var.env}-replication-p2s"
  assume_role_policy = data.aws_iam_policy_document.replication_trust_primary.json
}
data "aws_iam_policy_document" "replication_primary_policy" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [module.primary.code_bucket_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObjectVersion", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${module.primary.code_bucket_arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags", "s3:ObjectOwnerOverrideToBucketOwner"]
    resources = ["${module.secondary.code_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "replication_primary_policy" {
  name   = "${var.project_name}-${var.env}-replication-p2s-policy"
  policy = data.aws_iam_policy_document.replication_primary_policy.json
}

resource "aws_iam_role_policy_attachment" "attach_replication_primary" {
  role       = aws_iam_role.replication_primary_to_secondary.name
  policy_arn = aws_iam_policy.replication_primary_policy.arn
}

resource "aws_s3_bucket_replication_configuration" "primary_to_secondary" {
  depends_on = [aws_s3_bucket_versioning.primary, aws_iam_role_policy_attachment.attach_replication_primary]
  role       = aws_iam_role.replication_primary_to_secondary.arn
  bucket     = module.primary.code_bucket
  rule {
    id     = "replicate-to-secondary"
    status = "Enabled"
    filter { prefix = "" }
    destination {
      bucket        = module.secondary.code_bucket_arn
      storage_class = "STANDARD"
      access_control_translation { owner = "Destination" }
      metrics { status = "Enabled" }
    }
  }
}
data "aws_iam_policy_document" "replication_trust_secondary" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "replication_secondary_to_primary" {
  provider           = aws.secondary
  name               = "${var.project_name}-${var.env}-replication-s2p"
  assume_role_policy = data.aws_iam_policy_document.replication_trust_secondary.json
}
data "aws_iam_policy_document" "replication_secondary_policy" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetReplicationConfiguration", "s3:ListBucket"]
    resources = [module.secondary.code_bucket_arn]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObjectVersion", "s3:GetObjectVersionAcl", "s3:GetObjectVersionTagging"]
    resources = ["${module.secondary.code_bucket_arn}/*"]
  }
  statement {
    effect    = "Allow"
    actions   = ["s3:ReplicateObject", "s3:ReplicateDelete", "s3:ReplicateTags", "s3:ObjectOwnerOverrideToBucketOwner"]
    resources = ["${module.primary.code_bucket_arn}/*"]
  }
}
resource "aws_iam_policy" "replication_secondary_policy" {
  provider = aws.secondary
  name     = "${var.project_name}-${var.env}-replication-s2p-policy"
  policy   = data.aws_iam_policy_document.replication_secondary_policy.json
}
resource "aws_iam_role_policy_attachment" "attach_replication_secondary" {
  provider   = aws.secondary
  role       = aws_iam_role.replication_secondary_to_primary.name
  policy_arn = aws_iam_policy.replication_secondary_policy.arn
}
resource "aws_s3_bucket_replication_configuration" "secondary_to_primary" {
  provider   = aws.secondary
  depends_on = [aws_s3_bucket_versioning.secondary, aws_iam_role_policy_attachment.attach_replication_secondary]
  role       = aws_iam_role.replication_secondary_to_primary.arn
  bucket     = module.secondary.code_bucket
  rule {
    id     = "replicate-to-primary"
    status = "Enabled"
    filter { prefix = "" }
    destination {
      bucket        = module.primary.code_bucket_arn
      storage_class = "STANDARD"
      access_control_translation { owner = "Destination" }
      metrics { status = "Enabled" }
    }
  }
}

# SNS + subscriptions
resource "aws_sns_topic" "alerts_primary" { name = "${var.project_name}-${var.env}-alerts-primary" }
resource "aws_sns_topic" "alerts_secondary" {
  provider = aws.secondary
  name     = "${var.project_name}-${var.env}-alerts-secondary"
}
resource "aws_sns_topic_subscription" "email_primary" {
  topic_arn = aws_sns_topic.alerts_primary.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

resource "aws_sns_topic_subscription" "email_secondary" {
  provider  = aws.secondary
  topic_arn = aws_sns_topic.alerts_secondary.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Alarms
resource "aws_cloudwatch_metric_alarm" "s3_repl_latency_primary" {
  alarm_name          = "${var.project_name}-${var.env}-s3-repl-latency-primary"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 900
  metric_name         = "ReplicationLatency"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Average"
  dimensions          = { BucketName = module.primary.code_bucket, RuleId = "replicate-to-secondary" }
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts_primary.arn]
  alarm_description   = "S3 replication latency in primary bucket is high."
}
resource "aws_cloudwatch_metric_alarm" "s3_repl_latency_secondary" {
  provider            = aws.secondary
  alarm_name          = "${var.project_name}-${var.env}-s3-repl-latency-secondary"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 900
  metric_name         = "ReplicationLatency"
  namespace           = "AWS/S3"
  period              = 300
  statistic           = "Average"
  dimensions          = { BucketName = module.secondary.code_bucket, RuleId = "replicate-to-primary" }
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts_secondary.arn]
  alarm_description   = "S3 replication latency in secondary bucket is high."
}

# Route53 health checks + alarms
data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = false
}
resource "aws_route53_health_check" "primary" {
  fqdn              = module.primary.alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
}
resource "aws_route53_health_check" "secondary" {
  fqdn              = module.secondary.alb_dns_name
  port              = 80
  type              = "HTTP"
  resource_path     = "/health"
  failure_threshold = 3
  request_interval  = 30
}

resource "aws_cloudwatch_metric_alarm" "r53_primary_hc" {
  provider            = aws.secondary
  alarm_name          = "${var.project_name}-${var.env}-r53-primary-hc"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.primary.id }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts_secondary.arn]
}
resource "aws_cloudwatch_metric_alarm" "r53_secondary_hc" {
  provider            = aws.secondary
  alarm_name          = "${var.project_name}-${var.env}-r53-secondary-hc"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  dimensions          = { HealthCheckId = aws_route53_health_check.secondary.id }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alerts_secondary.arn]
}

# Failover records
resource "aws_route53_record" "primary_failover" {
  zone_id        = data.aws_route53_zone.this.zone_id
  name           = "${var.record_name}.${var.domain_name}"
  type           = "A"
  set_identifier = "primary-${var.primary_region}"
  failover_routing_policy { type = "PRIMARY" }
  health_check_id = aws_route53_health_check.primary.id
  alias {
    name                   = module.primary.alb_dns_name
    zone_id                = module.primary.alb_zone_id
    evaluate_target_health = true
  }
}
resource "aws_route53_record" "secondary_failover" {
  zone_id        = data.aws_route53_zone.this.zone_id
  name           = "${var.record_name}.${var.domain_name}"
  type           = "A"
  set_identifier = "secondary-${var.secondary_region}"
  failover_routing_policy { type = "SECONDARY" }
  health_check_id = aws_route53_health_check.secondary.id
  alias {
    name                   = module.secondary.alb_dns_name
    zone_id                = module.secondary.alb_zone_id
    evaluate_target_health = true
  }
}


