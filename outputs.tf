output "nome_cluster" {
  value = aws_eks_cluster.principal.name
}

output "url_api" {
  description = "URL pública da API"
  value       = local.url_api
}

output "url_swagger" {
  value = "${local.url_api}/docs"
}

output "url_ecr" {
  value = aws_ecr_repository.app.repository_url
}

output "github_role_arn" {
  value = aws_iam_role.github_deploy.arn
}

output "comando_kubeconfig" {
  value = "aws eks update-kubeconfig --name ${aws_eks_cluster.principal.name} --region ${var.regiao}"
}
