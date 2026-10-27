# Menu Futé (catalogue de recettes, fiches imprimables, menu de la semaine) : Node 22 + Express + better-sqlite3.
# Les sources viennent du dépôt privé « menufute », copiées dans ./app par mac/mettre-a-jour-menufute.sh (contexte de build).
FROM node:22-slim
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev
COPY src src
COPY public public
ENV DB_PATH=/data/recipes.db NODE_ENV=production
USER node
EXPOSE 3000
CMD ["node", "src/server.js"]
