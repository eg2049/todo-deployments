#!/bin/bash

if ! [ -x "$(command -v docker-compose)" ]; then
  echo 'Error: docker-compose is not installed.' >&2
  exit 1
fi

container_name_certbot=${1}
container_name_ui=${2}
domains=(${3}) # example.com
email=${4} # Adding a valid address is strongly recommended
rsa_key_size=${5}
staging=${6} # Set to 1 if you're testing your setup to avoid hitting request limits else 0
data_path=${7}

if ! [ $container_name_certbot ]; then
    echo "ERROR: Please provide container name of certbot in docker-compose."
    exit 1
elif ! [ $container_name_ui ]; then
    echo "ERROR: Please provide container name of UI in docker-compose."
    exit 1
elif ! [ $domains ]; then
    echo "ERROR: Please provide the application domain."
    exit 1
elif ! [ $email ]; then
    echo "ERROR: Please provide email for the TLS certificate."
    exit 1
fi

if ! [ $rsa_key_size ]; then
    rsa_key_size=4096
fi

if ! [ $staging ]; then
    staging=0
fi

if ! [ $data_path ]; then
    data_path="./certs/certbot"
fi

if [ -d "$data_path" ]; then
  read -p "Existing data found for $domains. Continue and replace existing certificate? (y/N) " decision
  if [ "$decision" != "Y" ] && [ "$decision" != "y" ]; then
    exit
  fi
fi


if [ ! -e "$data_path/conf/options-ssl-nginx.conf" ] || [ ! -e "$data_path/conf/ssl-dhparams.pem" ]; then
  echo "### Downloading recommended TLS parameters ..."
  mkdir -p "$data_path/conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot-nginx/certbot_nginx/_internal/tls_configs/options-ssl-nginx.conf > "$data_path/conf/options-ssl-nginx.conf"
  curl -s https://raw.githubusercontent.com/certbot/certbot/master/certbot/certbot/ssl-dhparams.pem > "$data_path/conf/ssl-dhparams.pem"
  echo
fi

echo "### Creating dummy certificate for $domains ..."
path="/etc/letsencrypt/live/$domains"
mkdir -p "$data_path/conf/live/$domains"
docker-compose -f docker-compose.yaml -f docker-compose-prod.yaml run --rm --entrypoint "\
  openssl req -x509 -nodes -newkey rsa:$rsa_key_size -days 1\
    -keyout '$path/privkey.pem' \
    -out '$path/fullchain.pem' \
    -subj '/CN=localhost'" $container_name_certbot
echo


echo "### Starting $container_name_ui ..."
docker-compose -f docker-compose.yaml -f docker-compose-prod.yaml up --force-recreate -d $container_name_ui
echo

echo "### Deleting dummy certificate for $domains ..."
docker-compose -f docker-compose.yaml -f docker-compose-prod.yaml run --rm --entrypoint "\
  rm -Rf /etc/letsencrypt/live/$domains && \
  rm -Rf /etc/letsencrypt/archive/$domains && \
  rm -Rf /etc/letsencrypt/renewal/$domains.conf" $container_name_certbot
echo


echo "### Requesting Let's Encrypt certificate for $domains ..."
#Join $domains to -d args
domain_args=""
for domain in "${domains[@]}"; do
  domain_args="$domain_args -d $domain"
done

# Select appropriate email arg
case "$email" in
  "") email_arg="--register-unsafely-without-email" ;;
  *) email_arg="--email $email" ;;
esac

# Enable staging mode if needed
if [ $staging != "0" ]; then staging_arg="--staging"; fi

docker-compose -f docker-compose.yaml -f docker-compose-prod.yaml run --rm --entrypoint "\
  certbot certonly --webroot -w /var/www/certbot \
    $staging_arg \
    $email_arg \
    $domain_args \
    --rsa-key-size $rsa_key_size \
    --agree-tos \
    --force-renewal" $container_name_certbot
echo

echo "### Reloading $container_name_ui ..."
docker-compose -f docker-compose.yaml -f docker-compose-prod.yaml exec $container_name_ui nginx -s reload