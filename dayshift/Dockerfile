# Dayshift (webapp de contrôle des volets Somfy via l'API locale d'une TaHoma Switch) : Node 22, AUCUNE dépendance npm.
# Les sources viennent du dépôt privé « dayshift », copiées dans ./app par mac/mettre-a-jour-dayshift.sh (contexte de build).
# Les SECRETS (.env = adresse de la box et jeton de l'API locale ; rooms.json = pièces) ne sont JAMAIS dans l'image :
# l'application les cherche à des chemins fixes, redirigés par liens symboliques vers /data, volume monté depuis
# ./dayshift/data (hors git, droits 700). Sans /data/.env, l'application démarre en MODE DÉMO (faux volets, aucun effet réel).
FROM node:22-alpine
WORKDIR /app
COPY package.json server.js ./
COPY public public
RUN mkdir -p /data && chown node:node /data \
 && ln -s /data/.env /app/.env \
 && ln -s /data/rooms.json /app/rooms.json
USER node
ENV PORT=3000 LISTEN=0.0.0.0
EXPOSE 3000
CMD ["node", "server.js"]
