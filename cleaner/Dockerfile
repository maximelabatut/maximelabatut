# Roborock Cleaner (pilotage de l'aspirateur via Matter) : Node 22 + matter.js + Fastify, lancé avec tsx (TypeScript direct).
# Les sources viennent du dépôt privé « roborockcleaner », copiées dans ./app par mac/mettre-a-jour-cleaner.sh (contexte de build).
# Le jumelage Matter (.matter-storage, SECRET) n'est jamais dans l'image : il est monté depuis ./cleaner/matter-storage.
FROM node:22-slim
WORKDIR /app
RUN chown node:node /app
COPY --chown=node:node package*.json ./
USER node
RUN npm ci --no-audit --no-fund
COPY --chown=node:node tsconfig.json ./
COPY --chown=node:node src src
COPY --chown=node:node public public
ENV NODE_ENV=production PORT=8091 HOST=127.0.0.1
CMD ["node_modules/.bin/tsx", "src/server.ts"]
