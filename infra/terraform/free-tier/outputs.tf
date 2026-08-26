output "ecs_cluster" {
  value = aws_ecs_cluster.ml.id
}
output "ecs_service" {
  value = aws_ecs_service.ml.id
}
output "lineage_bucket" {
  value = aws_s3_bucket.ml_lineage.id
}
output "health_url" {
  description = "Free-tier ingress (Lambda Function URL). Enterprise: replace with API Gateway endpoint."
  value       = aws_lambda_function_url.health.function_url
}
output "app_image" {
  value = var.ecr_image
}
