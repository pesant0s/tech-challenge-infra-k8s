#!/usr/bin/env bash
# Prepara os 4 repositórios para o ambiente efêmero (ADR-013). Requer gh autenticado.
set -euo pipefail

acao=${1:-}
[[ "$acao" =~ ^(ligar|desligar|status|segredos|implantar)$ ]] || {
  echo "uso: $0 {ligar|desligar|status|segredos|implantar}" >&2
  exit 2
}

REPOS=(tech-challenge-app tech-challenge-infra-db tech-challenge-infra-k8s tech-challenge-auth-lambda)
dono=${GITHUB_OWNER:-$(git config --get remote.origin.url | sed -E 's#^.*github\.com[:/]([^/]+)/.*$#\1#')} || {
  echo "Defina GITHUB_OWNER ou configure o remote 'origin'." >&2
  exit 1
}
command -v gh >/dev/null || { echo "Instale o GitHub CLI: https://cli.github.com" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "Autentique o gh: gh auth login" >&2; exit 1; }

case "$acao" in
  ligar|desligar)
    valor=$([[ "$acao" == ligar ]] && echo true || echo false)
    for repo in "${REPOS[@]}"; do
      gh variable set AMBIENTE_ATIVO --body "$valor" --repo "$dono/$repo"
      echo "✓ $repo AMBIENTE_ATIVO=$valor"
    done
    ;;
  status)
    for repo in "${REPOS[@]}"; do
      printf '%-28s %s\n' "$repo" "$(gh variable get AMBIENTE_ATIVO --repo "$dono/$repo" 2>/dev/null || echo 'não definida')"
    done
    ;;
  segredos)
    # O ARN não muda entre sessões: a role renasce com o mesmo nome.
    role="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/tech-challenge-github-deploy"
    for repo in "${REPOS[@]}"; do
      printf '%s' "$role" | gh secret set AWS_ROLE_ARN --repo "$dono/$repo"
    done
    if [[ -n "${NEW_RELIC_LICENSE_KEY:-}" ]]; then
      for repo in tech-challenge-app tech-challenge-infra-k8s; do
        printf '%s' "$NEW_RELIC_LICENSE_KEY" | gh secret set NEW_RELIC_LICENSE_KEY --repo "$dono/$repo"
      done
    else
      echo "⚠ NEW_RELIC_LICENSE_KEY não exportada: o New Relic fica desligado nos pipelines."
    fi
    echo "✓ segredos gravados em $dono"
    ;;
  implantar)
    for repo in tech-challenge-auth-lambda tech-challenge-app; do
      gh workflow run ci-cd.yml --ref main --repo "$dono/$repo"
      echo "✓ pipeline de $repo acionado"
    done
    ;;
esac
