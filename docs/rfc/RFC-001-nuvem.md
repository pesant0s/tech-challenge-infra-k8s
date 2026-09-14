# RFC-001 · Escolha da nuvem

| | |
|---|---|
| **Status** | Aceita |
| **Data** | 2026-09-07 |
| **Decisões derivadas** | ADR-002 (sem NAT), ADR-005 (NLB do Terraform), ADR-007 (OIDC), ADR-013 (ambiente efêmero) |

## Contexto

A Fase 03 exige, numa mesma nuvem, API Gateway, função serverless de autenticação, banco de
dados gerenciado, cluster Kubernetes com escalabilidade e provisionamento por Terraform.

O projeto não tem orçamento. O ambiente precisa custar o mínimo enquanto está ligado, nada
quando está desligado, e ser reproduzível pelos avaliadores em outra conta.

## Critérios

1. Todos os serviços obrigatórios disponíveis como gerenciados e cobertos pelo Terraform.
2. Função serverless alcançando o banco por rede privada, sem expor o banco à internet.
3. Custo por hora com o ambiente ligado.
4. Federação de identidade com o GitHub Actions, sem chave de acesso estática.
5. Experiência prévia do time, que reduz risco num prazo de fase.

## Opções

| Critério | AWS | Azure | Google Cloud |
|---|---|---|---|
| Kubernetes gerenciado | EKS | AKS | GKE |
| Gateway | API Gateway (HTTP API) | API Management | API Gateway |
| Função serverless | Lambda | Azure Functions | Cloud Run functions |
| PostgreSQL gerenciado | RDS | Database for PostgreSQL | Cloud SQL |
| Função na rede privada | Lambda em subnet privada, sem componente extra | integração com VNet só nos planos Premium e Flex Consumption | conector Serverless VPC Access ou saída direta para a VPC |
| Plano de controle do Kubernetes | US$ 0,10/h | sem cobrança no tier Free | crédito mensal cobre um cluster zonal |
| OIDC com GitHub Actions | sim | sim | sim |
| Experiência prévia do time | sim | não | não |

## Proposta

**AWS.** Os serviços se encaixam sem peças intermediárias: a Lambda roda na mesma VPC do RDS, o
API Gateway alcança o cluster por VPC Link, e uma única role OIDC atende os quatro pipelines. A
experiência prévia do time com a plataforma pesa num prazo curto.

## O que pesa contra

O plano de controle do EKS é cobrado por hora e não tem free tier. Nesse critério, AKS e GKE
seriam mais baratos. A proposta aceita o custo e o contém:

- ambiente efêmero, ligado apenas em sessões de trabalho, a cerca de US$ 0,14/h (ADR-013);
- sem NAT Gateway, com o banco e a Lambda em subnets sem rota para a internet (ADR-002);
- nodes em Spot (ADR-006);
- AWS Budget com alertas e todos os recursos marcados com `Project=tech-challenge`.

## Riscos

| Risco | Mitigação |
|---|---|
| Ambiente esquecido ligado | `make down`, alerta de budget e custo exposto no README |
| Versão do EKS sair do suporte padrão, que custa 6× | versão fixada em suporte padrão, com o motivo na própria variável |
| Dependência de serviços específicos da AWS | integração por contratos no SSM e aplicação em container; o domínio não conhece a nuvem |

## Quando revisitar

Se o ambiente precisasse ficar ligado o mês inteiro sem orçamento, o custo do plano de controle
passaria a decidir, e AKS ou GKE voltariam a ser candidatos.
