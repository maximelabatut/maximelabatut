# Calendar : planning périscolaire, menus de cantine et factures du portail famille d'une mairie (lecture seule du portail).
# Node 22, AUCUNE dépendance npm. Sources du dépôt privé « calendar », copiées dans ./app par mac/mettre-a-jour-calendar.sh.
# Données et secrets dans /app/data (volume ./calendar/data, droits 700, hors git, NON sauvegardés) : .env (PORTAIL_EMAIL,
# PORTAIL_PASSWORD), historique.json, factures.json. Authentification déléguée à Cloudflare Access (AUTH_DELEGUEE=1 et ALLOWED_HOSTS
# fixés dans le compose) : sans l'un des deux, l'application REFUSE de démarrer dès qu'elle écoute sur le réseau.
FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY src src
RUN mkdir -p data && chown node:node data
USER node
ENV HOST=0.0.0.0 PORT=3000
EXPOSE 3000
# /healthz répond « ok » sans lire le portail.
HEALTHCHECK --interval=60s --timeout=10s --retries=3 --start-period=20s \
  CMD node -e "fetch('http://127.0.0.1:3000/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "--env-file-if-exists=data/.env", "src/server.js"]
