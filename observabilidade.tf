# Dashboards, alertas, monitor de uptime e métricas da Lambda no New Relic (ADR-014).
locals {
  newrelic_ativo = nonsensitive(var.newrelic_api_key != "") && var.newrelic_account_id != ""
  email_ativo    = local.newrelic_ativo && var.email_alertas != ""
  monitor        = "${var.prefixo}-api-health"
  logs_os        = "FROM Log WHERE evento = 'os_status'"
  app            = "FROM Transaction WHERE appName = 'tech-challenge-oficina'"
  pods           = "FROM K8sContainerSample WHERE clusterName = '${var.newrelic_cluster_name}' AND namespaceName = 'oficina'"

  alertas = {
    falha_os = {
      nome     = "Falha no processamento de ordens de serviço"
      consulta = "SELECT filter(count(*), WHERE http_status >= 500 OR level = 'ERROR') FROM Log WHERE logger = 'oficina.http' AND http_path LIKE '/atendimento/os%'"
      janela   = 60
    }
    api_fora_do_ar = {
      nome     = "API fora do ar para o monitor externo"
      consulta = "SELECT filter(count(*), WHERE result != 'SUCCESS') FROM SyntheticCheck WHERE monitorName = '${local.monitor}'"
      janela   = 300
    }
  }
}

resource "newrelic_one_dashboard" "oficina" {
  count = local.newrelic_ativo ? 1 : 0
  name  = "Tech Challenge · Oficina"

  page {
    name = "Ordens de serviço"

    widget_billboard {
      title  = "OS abertas hoje"
      row    = 1
      column = 1
      width  = 3
      nrql_query {
        query = "SELECT count(*) ${local.logs_os} AND status_anterior IS NULL SINCE today"
      }
    }

    widget_line {
      title  = "Volume diário de OS"
      row    = 1
      column = 4
      width  = 9
      nrql_query {
        query = "SELECT count(*) AS 'OS abertas' ${local.logs_os} AND status_anterior IS NULL SINCE 7 days ago TIMESERIES 1 day"
      }
    }

    widget_bar {
      title  = "Tempo médio por status (minutos)"
      row    = 4
      column = 1
      width  = 5
      nrql_query {
        query = "SELECT average(segundos_no_status_anterior) / 60 AS 'minutos' ${local.logs_os} AND status_anterior IN ('EM_DIAGNOSTICO', 'EM_EXECUCAO', 'FINALIZADA') FACET status_anterior SINCE 7 days ago"
      }
    }

    widget_table {
      title  = "Últimas mudanças de status"
      row    = 4
      column = 6
      width  = 7
      nrql_query {
        query = "SELECT os_id, status_anterior, status_novo, segundos_no_status_anterior, correlation_id ${local.logs_os} SINCE 1 day ago LIMIT 50"
      }
    }
  }

  page {
    name = "API e integrações"

    widget_line {
      title  = "Latência da API (ms)"
      row    = 1
      column = 1
      width  = 6
      nrql_query {
        query = "SELECT percentile(duration * 1000, 95) AS 'p95', average(duration * 1000) AS 'média' ${local.app} TIMESERIES"
      }
    }

    widget_billboard {
      title  = "Uptime em 24h (monitor externo)"
      row    = 1
      column = 7
      width  = 3
      nrql_query {
        query = "SELECT percentage(count(*), WHERE result = 'SUCCESS') AS 'uptime' FROM SyntheticCheck WHERE monitorName = '${local.monitor}' SINCE 1 day ago"
      }
    }

    widget_line {
      title  = "Healthcheck externo (ms)"
      row    = 1
      column = 10
      width  = 3
      nrql_query {
        query = "SELECT average(duration) FROM SyntheticCheck WHERE monitorName = '${local.monitor}' TIMESERIES"
      }
    }

    widget_line {
      title  = "Erros por componente"
      row    = 4
      column = 1
      width  = 6
      nrql_query {
        query = "SELECT count(*) FROM Log WHERE level = 'ERROR' FACET logger TIMESERIES"
      }
    }

    widget_line {
      title  = "Lambda de autenticação"
      row    = 4
      column = 7
      width  = 6
      nrql_query {
        query = "SELECT sum(provider.invocations.Sum) AS 'invocações', sum(provider.errors.Sum) AS 'erros' FROM ServerlessSample WHERE provider = 'LambdaFunction' TIMESERIES"
      }
    }
  }

  page {
    name = "Kubernetes"

    widget_line {
      title  = "CPU por pod (cores)"
      row    = 1
      column = 1
      width  = 6
      nrql_query {
        query = "SELECT average(cpuUsedCores) ${local.pods} FACET podName TIMESERIES"
      }
    }

    widget_line {
      title  = "Memória por pod (MiB)"
      row    = 1
      column = 7
      width  = 6
      nrql_query {
        query = "SELECT average(memoryWorkingSetBytes) / 1024 / 1024 ${local.pods} FACET podName TIMESERIES"
      }
    }

    widget_line {
      title  = "Réplicas do HPA"
      row    = 4
      column = 1
      width  = 6
      nrql_query {
        query = "SELECT latest(currentReplicas) AS 'atuais', latest(desiredReplicas) AS 'desejadas' FROM K8sHpaSample WHERE clusterName = '${var.newrelic_cluster_name}' AND namespaceName = 'oficina' TIMESERIES"
      }
    }

    widget_billboard {
      title  = "Reinícios de container na última hora"
      row    = 4
      column = 7
      width  = 6
      nrql_query {
        query = "SELECT sum(restartCountDelta) ${local.pods} SINCE 1 hour ago"
      }
    }
  }
}

resource "newrelic_synthetics_monitor" "health" {
  count            = local.newrelic_ativo ? 1 : 0
  name             = local.monitor
  type             = "SIMPLE"
  uri              = "${local.url_api}/health"
  period           = "EVERY_5_MINUTES"
  status           = "ENABLED"
  locations_public = ["US_EAST_1"]
}

resource "newrelic_alert_policy" "oficina" {
  count               = local.newrelic_ativo ? 1 : 0
  name                = "Tech Challenge · Oficina"
  incident_preference = "PER_CONDITION"
}

resource "newrelic_nrql_alert_condition" "oficina" {
  for_each = local.newrelic_ativo ? local.alertas : {}

  policy_id                    = newrelic_alert_policy.oficina[0].id
  type                         = "static"
  name                         = each.value.nome
  enabled                      = true
  violation_time_limit_seconds = 86400
  aggregation_window           = each.value.janela
  # Toda requisição ou check gera ponto de dado (0 quando não há falha), então o incidente fecha na recuperação;
  # sem tráfego nenhum, a perda de sinal fecha o que estiver aberto.
  aggregation_method             = "event_timer"
  aggregation_timer              = each.value.janela
  fill_option                    = "static"
  fill_value                     = 0
  expiration_duration            = each.value.janela * 3
  open_violation_on_expiration   = false
  close_violations_on_expiration = true

  nrql {
    query = each.value.consulta
  }

  critical {
    operator              = "above"
    threshold             = 0
    threshold_duration    = each.value.janela
    threshold_occurrences = "at_least_once"
  }
}

resource "newrelic_notification_destination" "email" {
  count = local.email_ativo ? 1 : 0
  name  = "${var.prefixo}-email"
  type  = "EMAIL"

  property {
    key   = "email"
    value = var.email_alertas
  }
}

resource "newrelic_notification_channel" "email" {
  count          = local.email_ativo ? 1 : 0
  name           = "${var.prefixo}-email"
  type           = "EMAIL"
  product        = "IINT"
  destination_id = newrelic_notification_destination.email[0].id

  property {
    key   = "subject"
    value = "Tech Challenge: {{issueTitle}}"
  }
}

resource "newrelic_workflow" "email" {
  count                 = local.email_ativo ? 1 : 0
  name                  = "${var.prefixo}-alertas"
  muting_rules_handling = "NOTIFY_ALL_ISSUES"

  issues_filter {
    name = "politica-oficina"
    type = "FILTER"

    predicate {
      attribute = "labels.policyIds"
      operator  = "EXACTLY_MATCHES"
      values    = [newrelic_alert_policy.oficina[0].id]
    }
  }

  destination {
    channel_id = newrelic_notification_channel.email[0].id
  }
}

# 754728514883 é a conta AWS das integrações de nuvem do New Relic; o ExternalId é o ID da conta dele.
resource "aws_iam_role" "newrelic" {
  count = local.newrelic_ativo ? 1 : 0
  name  = "${var.prefixo}-newrelic"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::754728514883:root" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "sts:ExternalId" = var.newrelic_account_id } }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "newrelic" {
  count      = local.newrelic_ativo ? 1 : 0
  role       = aws_iam_role.newrelic[0].name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

resource "newrelic_cloud_aws_link_account" "principal" {
  count                  = local.newrelic_ativo ? 1 : 0
  name                   = var.prefixo
  arn                    = aws_iam_role.newrelic[0].arn
  metric_collection_mode = "PULL"

  depends_on = [aws_iam_role_policy_attachment.newrelic]
}

resource "newrelic_cloud_aws_integrations" "principal" {
  count             = local.newrelic_ativo ? 1 : 0
  linked_account_id = newrelic_cloud_aws_link_account.principal[0].id

  lambda {
    aws_regions              = [var.regiao]
    metrics_polling_interval = 300
    fetch_tags               = true
  }
}
