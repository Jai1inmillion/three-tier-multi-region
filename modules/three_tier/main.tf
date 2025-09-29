# VPC + networking + S3 + ALB/ASGs (no DB in this module)

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = "${var.name_prefix}-vpc" }
}

resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.name_prefix}-igw" }
}

locals {
  public_subnets = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i)]
  app_subnets    = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
  db_subnets     = [for i, az in var.azs : cidrsubnet(var.vpc_cidr, 8, i + 20)]
}

resource "aws_subnet" "public" {
  for_each                = { for idx, az in var.azs : idx => { az = az, cidr = local.public_subnets[idx] } }
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name_prefix}-public-${each.value.az}" }
}

resource "aws_eip" "nat" {
  for_each   = aws_subnet.public
  domain     = "vpc"
  depends_on = [aws_internet_gateway.igw]
  tags       = { Name = "${var.name_prefix}-nat-eip-${each.value.availability_zone}" }
}

resource "aws_nat_gateway" "nat" {
  for_each      = aws_subnet.public
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = { Name = "${var.name_prefix}-nat-${each.value.availability_zone}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
  tags = { Name = "${var.name_prefix}-rtb-public" }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_subnet" "app" {
  for_each          = { for idx, az in var.azs : idx => { az = az, cidr = local.app_subnets[idx] } }
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = { Name = "${var.name_prefix}-app-${each.value.az}" }
}

resource "aws_subnet" "db" {
  for_each          = { for idx, az in var.azs : idx => { az = az, cidr = local.db_subnets[idx] } }
  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = { Name = "${var.name_prefix}-db-${each.value.az}" }
}

resource "aws_route_table" "app" {
  for_each = aws_nat_gateway.nat
  vpc_id   = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[each.key].id
  }
  tags = { Name = "${var.name_prefix}-rtb-app-${each.key}" }
}

resource "aws_route_table_association" "app" {
  for_each       = aws_subnet.app
  subnet_id      = each.value.id
  route_table_id = aws_route_table.app[each.key].id
}

resource "aws_route_table" "db" {
  for_each = aws_nat_gateway.nat
  vpc_id   = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.nat[each.key].id
  }
  tags = { Name = "${var.name_prefix}-rtb-db-${each.key}" }
}

resource "aws_route_table_association" "db" {
  for_each       = aws_subnet.db
  subnet_id      = each.value.id
  route_table_id = aws_route_table.db[each.key].id
}

# S3 bucket for code (private)
resource "aws_s3_bucket" "code" {
  bucket = var.code_bucket_name
  tags   = { Name = "${var.name_prefix}-code" }
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# IAM for EC2 to read S3
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}
resource "aws_iam_role" "ec2_role" {
  name               = "${var.name_prefix}-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

data "aws_iam_policy_document" "s3_readonly" {
  statement {
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.code.arn, "${aws_s3_bucket.code.arn}/*"]
  }
}
resource "aws_iam_policy" "s3_readonly" {
  name   = "${var.name_prefix}-s3-readonly"
  policy = data.aws_iam_policy_document.s3_readonly.json
}
resource "aws_iam_role_policy_attachment" "attach_s3" {
  role       = aws_iam_role.ec2_role.name
  policy_arn = aws_iam_policy.s3_readonly.arn
}
resource "aws_iam_instance_profile" "ec2_profile" {
  name = "${var.name_prefix}-ec2-profile"
  role = aws_iam_role.ec2_role.name
}

# SGs
resource "aws_security_group" "alb_sg" {
  name        = "${var.name_prefix}-alb-sg"
  description = "HTTP from anywhere to ALB"
  vpc_id      = aws_vpc.this.id
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}
resource "aws_security_group" "web_sg" {
  name   = "${var.name_prefix}-web-sg"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "app_sg" {
  name   = "${var.name_prefix}-app-sg"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db_sg" {
  name   = "${var.name_prefix}-db-sg"
  vpc_id = aws_vpc.this.id
  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.app_sg.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# AMI
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["137112412989"]
  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }
}

locals {
  web_user_data_rendered = replace(var.web_user_data, "__REPLACE_AT_RUNTIME__", aws_s3_bucket.code.bucket)
  app_user_data_rendered = replace(var.app_user_data, "__REPLACE_AT_RUNTIME__", aws_s3_bucket.code.bucket)
}

# ALB + Web ASG
resource "aws_launch_template" "web" {
  name_prefix   = "${var.name_prefix}-web-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.web_instance_type
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  vpc_security_group_ids = [aws_security_group.web_sg.id]
  user_data              = base64encode(local.web_user_data_rendered)
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-web" }
  }
}

resource "aws_lb" "alb" {
  name               = substr("${var.name_prefix}-alb", 0, 32)
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [for s in aws_subnet.public : s.id]
}

resource "aws_lb_target_group" "web" {
  name     = substr("${var.name_prefix}-tg-web", 0, 32)
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.this.id
  health_check {
    path                = "/health"
    matcher             = "200-399"
    interval            = 30
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = 80
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}

resource "aws_autoscaling_group" "web" {
  name                = "${var.name_prefix}-asg-web"
  desired_capacity    = var.web_desired
  max_size            = max(var.web_desired, 4)
  min_size            = 1
  vpc_zone_identifier = [for s in aws_subnet.public : s.id]
  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }
  target_group_arns = [aws_lb_target_group.web.arn]
  health_check_type = "EC2"
  lifecycle { create_before_destroy = true }
}

# App ASG
resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-app-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.app_instance_type
  iam_instance_profile { name = aws_iam_instance_profile.ec2_profile.name }
  vpc_security_group_ids = [aws_security_group.app_sg.id]
  user_data              = base64encode(local.app_user_data_rendered)
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name_prefix}-app" }
  }
}
resource "aws_autoscaling_group" "app" {
  name                = "${var.name_prefix}-asg-app"
  desired_capacity    = var.app_desired
  max_size            = max(var.app_desired, 4)
  min_size            = 1
  vpc_zone_identifier = [for s in aws_subnet.app : s.id]
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  health_check_type = "EC2"
  lifecycle { create_before_destroy = true }
}


