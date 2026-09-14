data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_policy_document" "confianca_github" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Só a main dos repositórios do dono. O GitHub envia o sub no formato clássico (repo:dono/repo)
    # ou com IDs imutáveis (repo:dono@id/repo@id); os dois são aceitos, com o ID do dono fixado.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([for repo in var.repos_github : [
        "repo:${var.org_github}/${repo}:ref:refs/heads/main",
        "repo:${var.org_github}@${var.id_dono_github}/${repo}@*:ref:refs/heads/main",
      ]])
    }
  }
}

resource "aws_iam_role" "github_deploy" {
  name               = "${var.prefixo}-github-deploy"
  description        = "Assumida pelos pipelines via OIDC"
  assume_role_policy = data.aws_iam_policy_document.confianca_github.json
}

# Três pipelines rodam Terraform (VPC, RDS, EKS, IAM); o limite é a confiança acima (ADR-007).
resource "aws_iam_role_policy_attachment" "github_deploy" {
  role       = aws_iam_role.github_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

# Autenticar na AWS não autoriza no cluster: o EKS exige access entry.
resource "aws_eks_access_entry" "github_deploy" {
  cluster_name  = aws_eks_cluster.principal.name
  principal_arn = aws_iam_role.github_deploy.arn
  type          = "STANDARD"
}

resource "aws_eks_access_policy_association" "github_deploy" {
  cluster_name  = aws_eks_cluster.principal.name
  principal_arn = aws_iam_role.github_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.github_deploy]
}
