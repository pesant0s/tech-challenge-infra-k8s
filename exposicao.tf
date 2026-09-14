# Internet → API Gateway → VPC Link → NLB → NodePort 30080 → pods.
# O NLB é do Terraform para o gateway integrar sem depender do deploy da API (ADR-005).

locals {
  node_port = 30080
}

resource "aws_lb" "api" {
  name               = "${var.prefixo}-nlb"
  load_balancer_type = "network"
  internal           = true
  subnets            = local.subnets_privadas

  tags = { Name = "${var.prefixo}-nlb" }
}

resource "aws_lb_target_group" "api" {
  name                 = "${var.prefixo}-tg"
  port                 = local.node_port
  protocol             = "TCP"
  target_type          = "instance"
  vpc_id               = local.vpc_id
  deregistration_delay = 30 # o padrão de 300 s é longo demais para interrupção Spot

  health_check {
    protocol            = "HTTP"
    path                = "/health"
    port                = tostring(local.node_port)
    healthy_threshold   = 2
    unhealthy_threshold = 2
    interval            = 15
  }
}

resource "aws_lb_listener" "api" {
  load_balancer_arn = aws_lb.api.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

resource "aws_autoscaling_attachment" "nodes" {
  autoscaling_group_name = aws_eks_node_group.principal.resources[0].autoscaling_groups[0].name
  lb_target_group_arn    = aws_lb_target_group.api.arn
}

resource "aws_vpc_security_group_ingress_rule" "nodeport" {
  security_group_id = aws_eks_cluster.principal.vpc_config[0].cluster_security_group_id
  description       = "NodePort da API a partir do NLB interno"
  cidr_ipv4         = local.cidr_vpc
  from_port         = local.node_port
  to_port           = local.node_port
  ip_protocol       = "tcp"
}

resource "aws_security_group" "vpc_link" {
  name        = "${var.prefixo}-vpc-link"
  description = "VPC Link do API Gateway"
  vpc_id      = local.vpc_id

  tags = { Name = "${var.prefixo}-vpc-link" }
}

resource "aws_vpc_security_group_egress_rule" "vpc_link_para_nlb" {
  security_group_id = aws_security_group.vpc_link.id
  description       = "Saida para o NLB"
  cidr_ipv4         = local.cidr_vpc
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

resource "aws_apigatewayv2_vpc_link" "principal" {
  name               = "${var.prefixo}-vpc-link"
  subnet_ids         = local.subnets_privadas
  security_group_ids = [aws_security_group.vpc_link.id]
}

resource "aws_apigatewayv2_api" "principal" {
  name          = "${var.prefixo}-api"
  description   = "Porta de entrada unica da oficina mecanica"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["authorization", "content-type", "x-request-id"]
  }
}

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/${var.prefixo}"
  retention_in_days = 7
}

resource "aws_apigatewayv2_stage" "principal" {
  api_id      = aws_apigatewayv2_api.principal.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      responseLength = "$context.responseLength"
      latenciaMs     = "$context.responseLatency"
      erroIntegracao = "$context.integrationErrorMessage"
    })
  }

  default_route_settings {
    detailed_metrics_enabled = true
    throttling_burst_limit   = 100
    throttling_rate_limit    = 50
  }
}

# No stage $default a invoke_url termina em "/"; sem o corte, quem monta "${url}/rota" gera "//rota".
locals {
  url_api = trimsuffix(aws_apigatewayv2_stage.principal.invoke_url, "/")
}

resource "aws_apigatewayv2_integration" "eks" {
  api_id             = aws_apigatewayv2_api.principal.id
  integration_type   = "HTTP_PROXY"
  integration_uri    = aws_lb_listener.api.arn
  integration_method = "ANY"
  connection_type    = "VPC_LINK"
  connection_id      = aws_apigatewayv2_vpc_link.principal.id

  # O requestId do gateway vira o correlation_id da API.
  request_parameters = {
    "overwrite:header.x-request-id" = "$context.requestId"
  }
}

# A rota /auth/cpf é criada pelo tech-challenge-auth-lambda (ADR-012).
resource "aws_apigatewayv2_route" "coringa" {
  api_id    = aws_apigatewayv2_api.principal.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.eks.id}"
}
