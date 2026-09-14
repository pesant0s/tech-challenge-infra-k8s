variable "regiao" {
  description = "Região AWS"
  type        = string
  default     = "us-east-1"
}

variable "perfil_aws" {
  description = "Perfil local do AWS CLI; vazio no CI, que usa OIDC"
  type        = string
  default     = null
}

variable "prefixo" {
  description = "Prefixo dos nomes de recurso"
  type        = string
  default     = "tech-challenge"
}

variable "versao_kubernetes" {
  description = "Versão do EKS; precisa estar em suporte padrão, pois o estendido custa 6x"
  type        = string
  default     = "1.36"
}

variable "tipos_instancia" {
  description = "Tipos aceitos para os nodes; mais de um aumenta a chance de capacidade Spot"
  type        = list(string)
  default     = ["t3.small", "t3a.small"]
}

variable "capacidade_spot" {
  description = "Nodes em Spot, cerca de 70% mais baratos"
  type        = bool
  default     = true
}

variable "nodes_desejados" {
  description = "Quantidade inicial de nodes"
  type        = number
  default     = 2
}

variable "nodes_minimo" {
  description = "Mínimo de nodes"
  type        = number
  default     = 2
}

variable "nodes_maximo" {
  description = "Máximo de nodes"
  type        = number
  default     = 4
}

variable "org_github" {
  description = "Dono dos repositórios no GitHub; restringe quem assume a role de deploy"
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9-]+$", var.org_github))
    error_message = "org_github deve ser um usuário ou organização do GitHub, sem barras."
  }
}

variable "repos_github" {
  description = "Repositórios autorizados a assumir a role via OIDC"
  type        = list(string)
  default = [
    "tech-challenge-app",
    "tech-challenge-infra-k8s",
    "tech-challenge-infra-db",
    "tech-challenge-auth-lambda",
  ]
}

variable "newrelic_license_key" {
  description = "Licença do New Relic; vazia, o agente não é instalado"
  type        = string
  sensitive   = true
  default     = ""
}

variable "newrelic_api_key" {
  description = "User key do New Relic (NRAK-...); vazia, dashboards, alertas e monitor não são criados"
  type        = string
  sensitive   = true
  default     = ""
}

variable "newrelic_account_id" {
  description = "ID da conta no New Relic"
  type        = string
  default     = ""
}

variable "newrelic_regiao" {
  description = "Região da conta no New Relic: US ou EU"
  type        = string
  default     = "US"
}

variable "email_alertas" {
  description = "E-mail que recebe os alertas; vazio, os incidentes ficam só no painel do New Relic"
  type        = string
  default     = ""
}

variable "newrelic_cluster_name" {
  description = "Nome do cluster no New Relic"
  type        = string
  default     = "tech-challenge-eks"
}
