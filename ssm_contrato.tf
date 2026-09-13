# Contrato lido pelo auth-lambda e pelos Makefiles; mudar um parâmetro quebra quem o lê.

locals {
  parametros_publicados = {
    "cluster/nome"            = aws_eks_cluster.principal.name
    "apigateway/id"           = aws_apigatewayv2_api.principal.id
    "apigateway/endpoint"     = aws_apigatewayv2_stage.principal.invoke_url
    "apigateway/execucao_arn" = aws_apigatewayv2_api.principal.execution_arn
  }
}

resource "aws_ssm_parameter" "contrato" {
  for_each = local.parametros_publicados

  name        = "/tech-challenge/${each.key}"
  type        = "String"
  value       = each.value
  description = "Publicado por tech-challenge-infra-k8s. Nao editar manualmente."

  tags = { Contrato = "infra-k8s" }
}
