variable "project_name" {
  type    = string
  default = "three-tier"
}

variable "env" {
  type    = string
  default = "prod"
}

variable "primary_region" {
  type    = string
  default = "us-east-2"
}

variable "secondary_region" {
  type    = string
  default = "us-east-1"
}

variable "primary_vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "secondary_vpc_cidr" {
  type    = string
  default = "10.30.0.0/16"
}

variable "primary_azs" {
  type    = list(string)
  default = ["us-east-2a", "us-east-2b"]
}

variable "secondary_azs" {
  type    = list(string)
  default = ["us-east-1a", "us-east-1b"]
}

variable "code_bucket_prefix" {
  type    = string
  default = "tt-code"
}

variable "web_instance_type" {
  type    = string
  default = "t2.micro"
}
variable "app_instance_type" {
  type    = string
  default = "t2.micro"
}

variable "db_engine_version" {
  type    = string
  default = "8.0"
}

variable "db_instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "db_username" {
  type    = string
  default = "admin"
}

variable "db_password" {
  type      = string
  sensitive = true
}
variable "web_desired" {
  type    = number
  default = 2
}
variable "app_desired" {
  type    = number
  default = 2
}
variable "domain_name" {
  type        = string
  description = "cakesstreet.ca"
}

variable "record_name" {
  type    = string
  default = "www.cakesstreet.ca"
}

variable "alert_email" {
  type    = string
  default = "jaihanspal@gmail.com"
}
