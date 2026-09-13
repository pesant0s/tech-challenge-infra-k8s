.DEFAULT_GOAL := help
.PHONY: help conta preflight init fmt validate plan up down apply destroy kubeconfig output status custo ambiente-ligar ambiente-desligar ambiente-status github-segredos implantar

AWS_REGION ?= us-east-1
export AWS_REGION

CONTA  = $(shell aws sts get-caller-identity --query Account --output text)
BUCKET = tech-challenge-tfstate-$(CONTA)
# Delimitador `|` no sed: num Makefile, `#` abriria um comentário.
GITHUB_OWNER ?= $(shell git config --get remote.origin.url 2>/dev/null | sed -E 's|^.*github\.com[:/]([^/]+)/.*$$|\1|')
export GITHUB_OWNER
TF_VARS = -var "org_github=$(GITHUB_OWNER)"

help: ## Lista os alvos
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

conta: ## Mostra em qual conta AWS os comandos vão atuar
	@test -n "$$AWS_PROFILE$$AWS_ACCESS_KEY_ID" || { echo "Defina AWS_PROFILE com a conta que vai receber o cluster."; exit 1; }
	@echo "Conta AWS: $(CONTA) · perfil: $${AWS_PROFILE:-credenciais do ambiente} · região: $(AWS_REGION)"

preflight: conta
	@aws ssm get-parameter --name /tech-challenge/network/vpc_id >/dev/null 2>&1 || { echo "A rede do tech-challenge-infra-db não existe nesta conta: aplique aquele repositório primeiro."; exit 1; }
	@test -n "$(GITHUB_OWNER)" || { echo "Dono dos repositórios desconhecido: rode com GITHUB_OWNER=seu-usuario."; exit 1; }

init: conta ## Inicializa o Terraform com o estado desta conta
	terraform init -backend-config="bucket=$(BUCKET)" -backend-config="region=$(AWS_REGION)"

fmt: ## Formata os arquivos .tf
	terraform fmt -recursive

validate: ## Valida a configuração, sem AWS
	terraform init -backend=false -input=false >/dev/null
	terraform validate

plan: preflight ## Mostra o que será alterado
	@test -d .terraform || $(MAKE) --no-print-directory init
	terraform plan $(TF_VARS)

up: preflight ## Sobe o cluster (~15 min) e liga o ambiente nos pipelines. A cobrança começa aqui.
	@test -d .terraform || $(MAKE) --no-print-directory init
	terraform apply $(TF_VARS)
	@$(MAKE) --no-print-directory kubeconfig
	@./scripts/github.sh ligar || echo "⚠ AMBIENTE_ATIVO não foi ligado: rode 'make ambiente-ligar'."
	@echo "Ambiente no ar. Próximo passo: make implantar"

down: conta ## Desliga o ambiente nos pipelines e destrói o cluster
	@! aws lambda get-function --function-name tech-challenge-auth >/dev/null 2>&1 || { echo "A Lambda ainda existe: rode 'make destroy' no tech-challenge-auth-lambda."; exit 1; }
	@test -n "$(GITHUB_OWNER)" || { echo "Dono dos repositórios desconhecido: rode com GITHUB_OWNER=seu-usuario."; exit 1; }
	@./scripts/github.sh desligar || echo "⚠ AMBIENTE_ATIVO não foi desligado: rode 'make ambiente-desligar'."
	@test -d .terraform || $(MAKE) --no-print-directory init
	terraform destroy $(TF_VARS)

apply: up ## Sinônimo de up
destroy: down ## Sinônimo de down

github-segredos: conta ## Grava AWS_ROLE_ARN (e NEW_RELIC_LICENSE_KEY, se exportada) nos 4 repositórios
	@./scripts/github.sh segredos

ambiente-ligar: ## Liga AMBIENTE_ATIVO nos 4 repositórios
	@./scripts/github.sh ligar

ambiente-desligar: ## Desliga AMBIENTE_ATIVO nos 4 repositórios
	@./scripts/github.sh desligar

ambiente-status: ## Mostra AMBIENTE_ATIVO em cada repositório
	@./scripts/github.sh status

implantar: ## Aciona os pipelines da Lambda e da API na main
	@./scripts/github.sh implantar

kubeconfig: conta ## Aponta o kubectl para o cluster
	aws eks update-kubeconfig --name tech-challenge-eks --region $(AWS_REGION)

output: ## Exibe os outputs
	terraform output

status: ## Estado do cluster e das cargas
	@kubectl get nodes -o wide 2>/dev/null || echo "cluster inacessível: rode 'make kubeconfig'"
	@kubectl get pods,svc,hpa -n oficina 2>/dev/null || echo "namespace oficina ainda não existe"

custo: ## O que pesa enquanto o cluster está de pé
	@echo "EKS control plane  US\$$ 0,100/h (suporte padrão; no estendido, US\$$ 0,60)"
	@echo "2x t3.small Spot   US\$$ 0,014/h"
	@echo "NLB interno        US\$$ 0,023/h"
	@echo "EBS dos nodes      US\$$ 0,004/h"
	@echo "Total ligado       ~US\$$ 0,14/h"
