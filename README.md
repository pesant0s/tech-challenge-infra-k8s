# tech-challenge-infra-k8s — Cluster, Gateway e Observabilidade

Terraform que provisiona o **cluster Amazon EKS**, o **API Gateway**, o **ECR**, a
**federação OIDC com o GitHub** e a integração com o **New Relic**.

> Pós-Tech Software Architecture · FIAP · Tech Challenge Fase 03

> ⚠️ **Este é o repositório que custa dinheiro.** O control plane do EKS cobra
> US$ 0,10/hora esteja ele ocupado ou ocioso. Use `make up` para trabalhar e
> **`make down` ao terminar**. Uma sessão de 3 horas sai por ~US$ 0,45; um mês
> esquecido no ar, por ~US$ 100.

---

## Os quatro repositórios

| Repositório | Responsabilidade |
|---|---|
| `tech-challenge-infra-db` | VPC, RDS PostgreSQL, Secrets Manager — **aplicar primeiro** |
| **tech-challenge-infra-k8s** ← você está aqui | EKS, ECR, API Gateway, OIDC, New Relic |
| `tech-challenge-auth-lambda` | Autenticação por CPF; cria a própria rota neste gateway |
| `tech-challenge-app` | API REST da oficina, implantada neste cluster |

---

## Documentação

| Documento | Onde está |
|---|---|
| Diagrama de componentes | `tech-challenge-infra-k8s` · README, seção *Arquitetura* |
| Sequência da autenticação por CPF | `tech-challenge-infra-k8s` · README, *Fluxo de uma requisição autenticada* |
| Sequência da abertura de ordem de serviço | `tech-challenge-app` · README, *Abertura de uma ordem de serviço* |
| Modelo de dados: ER, relacionamentos e ajustes | `tech-challenge-app` · `docs/modelo-de-dados.md` |
| RFC-001 · Escolha da nuvem | `tech-challenge-infra-k8s` · `docs/rfc/RFC-001-nuvem.md` |
| RFC-002 · Escolha do banco de dados | `tech-challenge-infra-db` · `docs/rfc/RFC-002-banco-de-dados.md` |
| RFC-003 · Estratégia de autenticação | `tech-challenge-auth-lambda` · `docs/rfc/RFC-003-autenticacao.md` |
| ADR-001 a 004 · rede e banco | `tech-challenge-infra-db` · README |
| ADR-005 a 008, 013 e 014 · cluster, CI e observabilidade | `tech-challenge-infra-k8s` · README |
| ADR-009 a 012 · autenticação | `tech-challenge-auth-lambda` · README |
| Swagger | `<url_api>/docs` na AWS · `http://localhost:8000/docs` localmente |
| Coleção Postman | `tech-challenge-app` · `postman/oficina.postman_collection.json` |
| Ambientes e deploy ativo | só produção, com a dispensa de homologação registrada no README do `tech-challenge-app`; o ambiente AWS é efêmero (ADR-013), e a URL da API sai em `make output`, no `tech-challenge-infra-k8s`, durante uma sessão |


---

## Arquitetura

Diagrama de componentes da solução: nuvem, APIs, banco e monitoramento.

```mermaid
flowchart TB
    cliente["Cliente<br/>navegador · Postman"]

    subgraph aws["AWS · us-east-1"]
        apigw["API Gateway HTTP<br/>throttling · access logs"]

        subgraph vpc["VPC 10.0.0.0/16 — criada pelo infra-db"]
            subgraph publicas["Subnets públicas"]
                nodes["EKS Node Group<br/>2 a 4 × t3.medium Spot<br/>NodePort 30080"]
            end

            subgraph privadas["Subnets privadas"]
                nlb["NLB interno"]
                rds[("RDS PostgreSQL 16<br/>criptografado · TLS")]
                lambda["Lambda de autenticação"]
            end
        end

        ecr[("ECR<br/>oficina-api")]
        eks["EKS Control Plane<br/>metrics-server · CoreDNS"]
        sm[("Secrets Manager<br/>credenciais · SECRET_KEY")]
        cw["CloudWatch<br/>logs e métricas da Lambda"]
    end

    nr["New Relic<br/>APM · logs · métricas · alertas"]
    gh["GitHub Actions<br/>OIDC, sem chave estática"]

    cliente -->|HTTPS| apigw
    apigw -->|"/auth/*"| lambda
    apigw -->|"ANY /{proxy+}<br/>VPC Link"| nlb
    nlb -->|":30080"| nodes
    nodes -->|":5432"| rds
    lambda -->|":5432"| rds
    eks -.->|gerencia| nodes
    nodes -->|pull| ecr
    gh -->|push imagem| ecr
    gh -->|kubectl apply| eks
    nodes -.->|telemetria| nr
    lambda -.->|logs e métricas| cw
    cw -.->|métricas da Lambda| nr
    sm -.->|credenciais| lambda
    gh -->|lê credenciais no deploy| sm
    nr -.->|uptime: GET /health| apigw

    classDef custo fill:#f9e5d8,stroke:#b5651d,color:#5c3a1e
    class eks,nlb custo
```

Os blocos destacados são os que geram custo por hora.

### Fluxo de uma requisição autenticada

```mermaid
sequenceDiagram
    autonumber
    participant C as Cliente
    participant G as API Gateway
    participant L as Lambda de auth
    participant K as API no EKS
    participant D as RDS

    C->>G: POST /auth/cpf { cpf }
    G->>L: invoca
    L->>D: cliente existe e está ativo?
    D-->>L: dados do cliente
    L-->>G: JWT assinado com SECRET_KEY
    G-->>C: token

    Note over C,K: a partir daqui, com o token

    C->>G: POST /atendimento/os/{id}/aprovar + Bearer
    G->>K: VPC Link → NLB → NodePort<br/>x-request-id propagado
    K->>K: valida o JWT com a mesma SECRET_KEY<br/>e confere tipo = cliente
    K->>D: esta OS é do cliente do token?
    D-->>K: sim · AGUARDANDO_APROVACAO
    K->>D: status → RECEBIDA
    K-->>G: 200 + x-request-id
    G-->>C: 200
```

A `SECRET_KEY` que a Lambda usa para assinar e a que a API usa para validar são
**a mesma**, vinda do Secrets Manager criado no `infra-db`. Se divergirem, todo
token é rejeitado com erro genérico de credencial — vale conferir no primeiro teste.

---

## Decisões arquiteturais

A escolha da nuvem, comparada com Azure e Google Cloud, está na [RFC-001](docs/rfc/RFC-001-nuvem.md).

### ADR-005 · O NLB é do Terraform, não do Kubernetes

**Contexto.** O caminho idiomático seria um `Service` do tipo `LoadBalancer`, deixando
o AWS Load Balancer Controller provisionar o NLB.

**Problema.** Isso cria uma dependência circular: o API Gateway precisa do ARN do
listener para configurar a integração, mas esse listener só existiria **depois** que a
aplicação fosse implantada — e a aplicação só é implantada depois que o cluster e o
gateway existem. Não há ordem de `apply` que resolva.

**Decisão.** O Terraform é dono do NLB de ponta a ponta. O alvo é o **grupo de auto
scaling dos nodes**, que existe assim que o cluster sobe. O `Service` da aplicação vira
`NodePort` numa porta fixa, e o `kube-proxy` encaminha do node para o pod.

**Consequência.** A porta **30080** é contrato entre este repositório e o
`tech-challenge-app`. Em troca,
todo o caminho de rede é determinístico e provisionado por IaC — o que o desafio valoriza.

**Alternativa para um cenário real:** AWS Load Balancer Controller com Ingress, criando
a integração do gateway num segundo `apply`. Mais idiomático, porém com duas etapas.

---

### ADR-006 · Nodes em Spot com múltiplos tipos de instância

**Decisão.** `capacity_type = "SPOT"` com dois tipos aceitos, `t3.medium` e `t3a.medium`.

**Por que medium.** No EKS, o limite de pods por node vem das interfaces de rede: 11 num `t3.small`,
17 num `t3.medium`. Os pods de sistema e do New Relic ocupam sozinhos 18 vagas, e no primeiro ensaio
dois `t3.small` não deixaram espaço para a API.

**Motivo.** Spot custa ~70% menos. O risco é a interrupção com dois minutos de aviso —
mitigado por aceitar vários tipos (mais chance de encontrar capacidade) e manter no
mínimo dois nodes, com `PodDisruptionBudget` do lado da aplicação.

**Consequência.** Ambiente de demonstração pode perder um node no meio de uma sessão.
Para produção real, um node group On-Demand para cargas críticas e Spot para o resto.

---

### ADR-007 · Autenticação do CI por OIDC, sem chave estática

**Decisão.** O GitHub Actions assume uma role IAM apresentando um token OIDC assinado
pelo próprio GitHub. Nenhuma `AWS_ACCESS_KEY_ID` é guardada como secret.

**Motivo.** Chave estática não expira, não rotaciona sozinha e vaza em log com
facilidade. O token OIDC vale minutos e é emitido por execução.

**Detalhe que costuma falhar.** A condição de confiança restringe por `sub`:
`repo:<org>/<repo>:ref:refs/heads/main`. Sem ela, **qualquer repositório do GitHub** poderia
assumir a role; com `repo:<org>/<repo>:*`, bastaria um PR ou uma branch com o workflow alterado.
Como a `main` só recebe código por PR, apenas o que foi revisado e integrado chega à conta. Os
quatro repositórios autorizados estão em `var.repos_github`.

**Segunda armadilha.** Autenticar na AWS não basta para falar com o cluster: o EKS
separa autenticação de autorização. Por isso existem `aws_eks_access_entry` e
`aws_eks_access_policy_association` — sem eles o pipeline recebe `Unauthorized`
mesmo com credenciais válidas.

**Permissões.** A role tem `AdministratorAccess`, porque três dos quatro pipelines rodam
Terraform e criam VPC, RDS, EKS, IAM e Lambda. O limite é a confiança: só a `main` dos
quatro repositórios do dono assume a role, e só por OIDC. Em produção, uma role por pipeline,
com privilégio mínimo.

---

### ADR-008 · Uso de HPA e o metrics-server como pré-requisito

**Decisão.** O `metrics-server` é instalado como addon gerenciado do EKS.

**Motivo.** O HPA declarado na aplicação (2 a 6 réplicas, 70% de CPU) só funciona se
alguém publicar métricas de consumo na API do Kubernetes. Sem o metrics-server, o HPA
fica em `<unknown>/70%` e **nunca escala** — e a escalabilidade que o desafio pede
deixa de ser demonstrável.

**Consequência.** Não há Cluster Autoscaler: o node group fica nos 2 nodes desejados, e o máximo
de 4 vale para escala manual. Dois `t3.medium` somam 34 vagas de pod; tirando as 18 de sistema e do
New Relic, sobram 16, suficientes para as 6 réplicas do teto do HPA e o pod do teste de fumaça. Em
produção, Cluster Autoscaler ou Karpenter.

---

### ADR-013 · Ambiente efêmero, com uma chave de estado no GitHub

**Contexto.** O ambiente AWS só existe durante sessões de trabalho, porque o control plane
cobra por hora. A role OIDC que os quatro pipelines assumem nasce e morre com este cluster.
Com o ambiente desligado — o estado normal —, todo job que tentasse autenticar falharia:
pipelines vermelhos justamente quando alguém os abre para avaliar. E um merge na `main` deste
repositório poderia religar a cobrança sem ninguém perceber.

**Decisão.** Uma variável de repositório, `AMBIENTE_ATIVO`, nos quatro repositórios. O que não
precisa de AWS roda sempre: testes, validação, build e boot da imagem, empacotamento da
Lambda. O que precisa só roda com a variável em `true`; desligada, esses jobs aparecem como
pulados, com o motivo no resumo da execução. `make up` liga a variável ao final;
`make down` a desliga **antes** de destruir.

**Alternativas rejeitadas.**
- *Base persistente*, com role e ECR num estado separado que não é destruído a cada sessão:
  mantém recursos na conta entre sessões.
- *Chave de acesso de um usuário IAM* guardada no GitHub: credencial permanente e sem
  expiração, exatamente o que o ADR-007 rejeita.
- *Apply só por acionamento manual*: enfraquece o deploy automático e, sozinho, não resolve
  a autenticação.

**Consequências.**
- Entre sessões, só o bucket do estado sobrevive — e `make bootstrap-destroy`, no
  `tech-challenge-infra-db`, o apaga ao fim da entrega.
- PRs de infraestrutura têm validação, mas não `plan`: só a `main` assume a role (ADR-007).
- Falha real de autenticação com a variável em `true` continua vermelha, com mensagem que
  explica as causas prováveis. A chave não mascara erro.
- Como a role só existe enquanto o cluster existe, **nenhum pipeline consegue recriar o
  cluster do zero** — só alterar um que já está no ar. Ligar cobrança é sempre uma ação humana.

---

### ADR-014 · Observabilidade como código

**Decisão.** Dashboard, alertas, monitor de uptime e a coleta das métricas da Lambda são recursos
Terraform deste repositório, criados e destruídos junto com o cluster.

**Motivo.** Quem reproduz o ambiente em outra conta recebe o mesmo painel e os mesmos alertas,
sem montá-los à mão; e nenhum painel sobra apontando para um ambiente que já não existe.

**Como os dados chegam.**
- **Logs:** o `nri-bundle` coleta o stdout dos pods, e o JSON da aplicação vira atributos
  consultáveis (`evento`, `status_novo`, `http_status`...). O agente Python não encaminha logs,
  para não duplicar cada linha.
- **APM e traces:** o agente Python na imagem. Cada linha de log leva `trace.id`, que liga o log
  ao trace.
- **Lambda:** o New Relic lê as métricas no CloudWatch assumindo uma role somente leitura, com o
  ID da conta como `ExternalId`. Os logs da função continuam no CloudWatch.
- **Uptime:** um monitor sintético chama `/health` pelo API Gateway a cada 5 minutos.

**Consequência.** Entre o `make up` e o primeiro deploy da aplicação, o monitor falha e o alerta
de API fora do ar abre um incidente. É esperado e fecha sozinho quando a API responde.

---

## O que é criado

| Recurso | Detalhe |
|---|---|
| EKS Cluster | Kubernetes 1.36, logs de API e auditoria por 7 dias |
| Node Group | 2 a 4 × `t3.medium` Spot, subnets públicas |
| Addons | `vpc-cni`, `kube-proxy`, `coredns`, `metrics-server` |
| ECR | `oficina-api`, varredura no push, retenção das 10 últimas imagens |
| NLB interno | Alvo: grupo de auto scaling dos nodes na porta 30080 |
| API Gateway HTTP | Rota coringa para o cluster, throttling, access logs em JSON |
| VPC Link | Ligação privada entre o gateway e o NLB |
| OIDC + Role | `AdministratorAccess`, assumida só pela `main` dos quatro repositórios |
| Launch template | Coloca os nodes no grupo `cliente-db`, o único que o RDS aceita |
| New Relic | `nri-bundle` via Helm — infraestrutura, eventos, logs e Prometheus |
| Dashboard e alertas | Painel da oficina, 2 alertas e monitor de uptime (com a User key) |
| Role do New Relic | Somente leitura, para coletar as métricas da Lambda no CloudWatch |

---

## Como usar

> **Montando tudo do zero?** Siga o roteiro completo no README do `tech-challenge-infra-db`,
> seção *Do zero numa conta nova*. Esta seção cobre só este repositório.

### Pré-requisitos

1. **O `tech-challenge-infra-db` aplicado nesta conta.** O `make up` confere e recusa sem ele.
2. **`AWS_PROFILE` apontando para a conta:** `export AWS_PROFILE=seu-perfil`.
3. **`gh` autenticado**, com os quatro repositórios no seu GitHub.

### Subir

```bash
export NEW_RELIC_LICENSE_KEY=... NEW_RELIC_API_KEY=NRAK-... NEW_RELIC_ACCOUNT_ID=...   # opcionais
make github-segredos   # uma vez: AWS_ROLE_ARN e as chaves do New Relic exportadas — não mudam entre sessões
make up                # ~15 min · a cobrança começa aqui · liga AMBIENTE_ATIVO no final
make implantar         # aciona os pipelines da Lambda e da API
make output            # url_api e url_swagger
```

O dono dos repositórios é lido do remote `origin` e restringe quais repositórios podem
assumir a role de deploy. Para outro dono: `make up GITHUB_OWNER=seu-usuario`.

### Operar

```bash
make status            # nodes, pods, services e HPA
make ambiente-status   # AMBIENTE_ATIVO em cada repositório
make kubeconfig        # aponta o kubectl para o cluster
make custo             # o que está pesando agora
```

### Derrubar

```bash
make down              # desliga AMBIENTE_ATIVO, destrói · ~10 min · encerra a cobrança
```

O `down` recusa enquanto a Lambda existir: destrua o `tech-challenge-auth-lambda` antes. Também
recusa se o dashboard e os alertas existirem e `NEW_RELIC_API_KEY` não estiver exportada, porque
sem ela o Terraform não consegue apagá-los.
Depois deste, o `tech-challenge-infra-db`.

---

## Contrato publicado

Consumido pelo `auth-lambda` e pelos pipelines:

| Parâmetro | Conteúdo |
|---|---|
| `/tech-challenge/cluster/nome` | Nome do cluster EKS |
| `/tech-challenge/apigateway/id` | ID da API — o `auth-lambda` cria sua rota nela |
| `/tech-challenge/apigateway/endpoint` | URL pública da API |
| `/tech-challenge/apigateway/execucao_arn` | ARN de execução, para a permissão da Lambda |

---

## Custo

| Recurso | Por hora | Observação |
|---|---|---|
| EKS control plane | US$ 0,100 | sem free tier; só em versão com suporte padrão — no estendido, US$ 0,60 |
| 2 × t3.medium Spot | US$ 0,033 | ~70% de desconto |
| NLB interno | US$ 0,0225 | + custo por LCU processada |
| EBS dos nodes | US$ 0,004 | |
| API Gateway | ~US$ 0 | US$ 1,00 por milhão de requisições |
| ECR | ~US$ 0 | 500 MB grátis; a política de retenção segura o resto |
| Métricas da Lambda no New Relic | ~US$ 0 | leituras na API do CloudWatch a cada 5 min, centavos por sessão |
| **Total** | **~US$ 0,16/h** | ~US$ 3,80/dia · ~US$ 115/mês |

Configure um **AWS Budget** com alerta em US$ 5 e US$ 20. Todo recurso leva a tag
`Project=tech-challenge`, então o Cost Explorer isola esse gasto.

---

## Observabilidade

| Sinal | De onde vem |
|---|---|
| CPU, memória, réplicas do HPA e eventos do cluster | `nri-bundle` |
| Logs JSON dos pods, com `correlation_id` e `trace.id` | `nri-bundle`, a partir do stdout |
| APM: latência, erros e traces da API | agente Python na imagem da aplicação |
| Invocações e erros da Lambda | integração AWS por polling do CloudWatch |
| Uptime | monitor sintético em `GET /health`, a cada 5 minutos |

O access log do API Gateway registra `requestId`, latência e erro de integração, e o `requestId`
é propagado para a aplicação como `x-request-id`, costurando o log do gateway ao log do pod.

### Dashboard "Tech Challenge · Oficina"

| Página | Widgets |
|---|---|
| Ordens de serviço | OS abertas hoje · volume diário · tempo médio por status · últimas mudanças de status |
| API e integrações | latência p95 e média · uptime em 24h · healthcheck externo · erros por componente · Lambda |
| Kubernetes | CPU e memória por pod · réplicas do HPA · reinícios de container |

Os widgets de negócio leem o evento `os_status`, que a aplicação loga a cada mudança de status.

### Alertas

| Condição | Consulta |
|---|---|
| Falha no processamento de ordens de serviço | resposta 5xx ou erro em `/atendimento/os*`, em janela de 1 minuto |
| API fora do ar para o monitor externo | check sintético sem sucesso, em janela de 5 minutos |

Com `email_alertas` definido, os incidentes chegam por e-mail; sem ele, ficam em **Alerts → Issues**.

### Variáveis

| Variável | Para quê | Vazia |
|---|---|---|
| `newrelic_license_key` | instala o `nri-bundle` | cluster sobe sem agente |
| `newrelic_api_key` · `newrelic_account_id` | dashboard, alertas, monitor e integração AWS | nada disso é criado |
| `newrelic_regiao` | `US` (padrão) ou `EU` | — |
| `email_alertas` | destino dos alertas | incidentes só no painel |

Com `make`, elas vêm das variáveis de ambiente `NEW_RELIC_LICENSE_KEY`, `NEW_RELIC_API_KEY`,
`NEW_RELIC_ACCOUNT_ID` e `EMAIL_ALERTAS`, as mesmas que o `make github-segredos` grava no GitHub.
A User key (`USER`, começa com `NRAK-`) e o ID da conta ficam em **API keys**, no New Relic. Essa tela
pode mostrar só o ID da licença; o comando que busca o valor pela API, com a User key, está no roteiro
*Do zero numa conta nova*, no README do `tech-challenge-infra-db`. Para conta na região EU, use
`api.eu.newrelic.com` e `TF_VAR_newrelic_regiao=EU`.

---

## CI/CD

| Evento | `AMBIENTE_ATIVO` | O que acontece |
|---|---|---|
| Pull Request | qualquer | `fmt` e `validate`; sem `plan`, porque só a `main` assume a role |
| push em `main` ou execução manual | `true` | `plan` e `apply` no cluster que está no ar |
| push em `main` ou execução manual | ausente ou `false` | só validação; plan e apply **pulados**, com o motivo no resumo |

**Ambiente efêmero.** O ambiente AWS só existe durante as sessões de trabalho (`make up` e
`make down` no `tech-challenge-infra-k8s`), e a variável de repositório `AMBIENTE_ATIVO` diz ao
pipeline em que estado ele está — ver ADR-013 acima. **Job pulado não é falha**:
é o comportamento esperado com o ambiente desligado. Já uma falha de autenticação com a
variável em `true` fica vermelha e explica no log as causas prováveis.

A `main` é protegida: infraestrutura muda apenas por Pull Request revisado.

| Configuração no repositório | Tipo | Quem grava |
|---|---|---|
| `AWS_ROLE_ARN` | secret | `make github-segredos`, no `tech-challenge-infra-k8s` |
| `AMBIENTE_ATIVO` | variável | `make up` e `make down`, no `tech-challenge-infra-k8s` |
| `NEW_RELIC_LICENSE_KEY` | secret | `make github-segredos`, se a chave estiver exportada |
| `NEW_RELIC_API_KEY` · `NEW_RELIC_ACCOUNT_ID` | secret | `make github-segredos`, se estiverem exportadas |
| `EMAIL_ALERTAS` | variável | à mão, opcional |

O primeiro `apply` é sempre local (`make up`): a role que o pipeline assume nasce aqui.

---

## Stack

Terraform 1.10+ · AWS Provider 5.x · Amazon EKS 1.36 · Amazon ECR ·
API Gateway HTTP API · Network Load Balancer · IAM OIDC · Helm · New Relic ·
GitHub Actions
