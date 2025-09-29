
output "alb_dns_name" { value = aws_lb.alb.dns_name }
output "alb_zone_id" { value = aws_lb.alb.zone_id }
output "code_bucket" { value = aws_s3_bucket.code.bucket }
output "code_bucket_arn" { value = aws_s3_bucket.code.arn }
output "db_subnet_ids" { value = [for s in aws_subnet.db : s.id] }
output "db_sg_id" { value = aws_security_group.db_sg.id }
