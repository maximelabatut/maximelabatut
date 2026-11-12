# Sentinel (armement/désarmement d'une centrale d'alarme via une page web) : Python 3.11 + aiohttp + aritech-client.
# Les sources viennent du dépôt privé « sentinel », copiées dans ./app par mac/mettre-a-jour-sentinel.sh (contexte de build).
# Les SECRETS (config.json = IP, PIN et clé de chiffrement de la centrale ; webapp.json = mot de passe web ; journal des actions)
# ne sont JAMAIS dans l'image : l'application les cherche à des chemins fixes, redirigés par liens symboliques vers /data,
# volume monté depuis ./sentinel/data (hors git, droits 700).
FROM python:3.11-slim
RUN useradd --create-home --uid 1000 app
WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY webapp webapp
RUN mkdir -p /data && chown app:app /data \
 && ln -s /data/config.json /app/config.json \
 && ln -s /data/webapp.json /app/webapp/webapp.json \
 && ln -s /data/actions.log /app/webapp/actions.log \
 && ln -s /data/mot-de-passe-web.txt /app/mot-de-passe-web.txt
USER app
ENV PYTHONUNBUFFERED=1
EXPOSE 8080
CMD ["python", "webapp/server.py"]
