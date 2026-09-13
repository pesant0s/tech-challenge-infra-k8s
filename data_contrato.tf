# Rede publicada pelo tech-challenge-infra-db (ADR-003).

data "aws_ssm_parameter" "vpc_id" { name = "/tech-challenge/network/vpc_id" }
data "aws_ssm_parameter" "cidr_vpc" { name = "/tech-challenge/network/cidr" }
data "aws_ssm_parameter" "subnets_publicas" { name = "/tech-challenge/network/subnet_ids_publicas" }
data "aws_ssm_parameter" "subnets_privadas" { name = "/tech-challenge/network/subnet_ids_privadas" }
data "aws_ssm_parameter" "sg_cliente_db" { name = "/tech-challenge/network/sg_cliente_db_id" }

locals {
  vpc_id           = data.aws_ssm_parameter.vpc_id.value
  cidr_vpc         = data.aws_ssm_parameter.cidr_vpc.value
  subnets_publicas = split(",", data.aws_ssm_parameter.subnets_publicas.value)
  subnets_privadas = split(",", data.aws_ssm_parameter.subnets_privadas.value)
  sg_cliente_db    = data.aws_ssm_parameter.sg_cliente_db.value
  nome_cluster     = "${var.prefixo}-eks"
}
