resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${local.nome_cluster}/cluster"
  retention_in_days = 7
}

resource "aws_eks_cluster" "principal" {
  name     = local.nome_cluster
  role_arn = aws_iam_role.cluster.arn
  version  = var.versao_kubernetes

  vpc_config {
    subnet_ids              = local.subnets_publicas
    endpoint_public_access  = true # sem NAT, CI e kubectl local dependem dele
    endpoint_private_access = true
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.cluster, aws_cloudwatch_log_group.cluster]

  tags = { Name = local.nome_cluster }
}

# Coloca os nodes no grupo cliente-db, o único que o RDS aceita (ADR-004).
resource "aws_launch_template" "nodes" {
  name_prefix            = "${var.prefixo}-nodes-"
  vpc_security_group_ids = [aws_eks_cluster.principal.vpc_config[0].cluster_security_group_id, local.sg_cliente_db]

  # Igual ao padrão do node group gerenciado: IMDSv2 com hop 2 para pods que leem metadados.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.prefixo}-node", Project = "tech-challenge" }
  }
}

resource "aws_eks_node_group" "principal" {
  cluster_name    = aws_eks_cluster.principal.name
  node_group_name = "${var.prefixo}-nodes"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = local.subnets_publicas
  capacity_type   = var.capacidade_spot ? "SPOT" : "ON_DEMAND"
  instance_types  = var.tipos_instancia

  launch_template {
    id      = aws_launch_template.nodes.id
    version = aws_launch_template.nodes.latest_version
  }

  scaling_config {
    desired_size = var.nodes_desejados
    min_size     = var.nodes_minimo
    max_size     = var.nodes_maximo
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  tags = { Name = "${var.prefixo}-nodes" }
}

resource "aws_eks_addon" "essenciais" {
  # Sem o metrics-server o HPA não enxerga CPU e nunca escala (ADR-008).
  for_each = toset(["vpc-cni", "kube-proxy", "coredns", "metrics-server"])

  cluster_name                = aws_eks_cluster.principal.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.principal]
}
