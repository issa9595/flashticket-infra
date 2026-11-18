# Raccourcis du TD2. Prérequis : docker (compose), aws (AWS CLI), k6, node 20+, zip.
# L'AWS CLI parle à LocalStack : AWS_ENDPOINT_URL (défini ici et dans .env.example) et --endpoint-url explicite
# (l'AWS CLI v1 ignore AWS_ENDPOINT_URL pour SQS).
export AWS_ENDPOINT_URL ?= http://localhost:4566
export AWS_ACCESS_KEY_ID ?= test
export AWS_SECRET_ACCESS_KEY ?= test
export AWS_DEFAULT_REGION ?= eu-west-3
AWS ?= $(if $(AWS_CMD),$(AWS_CMD),aws --endpoint-url $(AWS_ENDPOINT_URL))

up:        ## démarre LocalStack (docker compose)
	docker compose up -d
	@until $(AWS) sts get-caller-identity >/dev/null 2>&1; do sleep 1; done; echo "LocalStack prêt."

down:      ## arrête LocalStack et efface son état
	docker compose down -v

reset:     ## repart d'un LocalStack vide (puis make bootstrap et make deploy)
	docker compose down -v
	$(MAKE) up

bootstrap: ## crée les ressources (à écrire : scripts/bootstrap.sh)
	bash scripts/bootstrap.sh

deploy:    ## déploie create-order et process-order (scripts/deploy.sh fourni, relançable)
	bash scripts/deploy.sh

load:      ## charge k6 : 50 req/s pendant 60 s
	k6 run -e URL=$$($(AWS) lambda list-function-url-configs --function-name create-order --query 'FunctionUrlConfigs[0].FunctionUrl' --output text) loadtest/k6.js

smoke:     ## tests de fumée : 202/400, doublon, DLQ (SMOKE_DLQ=0 pour sauter le test lent)
	bash scripts/smoke.sh

.PHONY: up down reset bootstrap deploy load smoke
