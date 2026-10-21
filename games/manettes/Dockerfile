# Serveur de manettes de Garden Brawl (téléphones) : sert la page manette + relaie la mise en relation (WebSocket).
# Sources copiées depuis le dépôt gardenbrawl : serveur/ et manette/ (voir ../README-jeux.md).
FROM node:22-alpine
WORKDIR /app
COPY serveur/package*.json serveur/
RUN cd serveur && npm ci --omit=dev
COPY serveur serveur
COPY manette manette
USER node
ENV PORT=8787
CMD ["node", "serveur/serveur.js"]
