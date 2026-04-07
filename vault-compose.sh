#!binsh
set -eu

ENV_FILE=compose.env
COMPOSE_FILE=docker-gecko-compose.yml

# secure temp file for decrypted env
TMP_ENV=$(mktemp)
chmod 600 $TMP_ENV

# prompt for password
printf Vault password  &2
stty -echo
IFS= read -r VAULT_PASS
stty echo
printf n &2

# create FIFO for password (keeps it out of process args and off disk)
PW_FIFO=$(mktemp -u)
mkfifo $PW_FIFO
chmod 600 $PW_FIFO

cleanup() {
  rm -f $TMP_ENV $PW_FIFO 2devnull  true
}
trap cleanup EXIT INT HUP TERM

# feed password into FIFO while ansible-vault runs
( printf %s $VAULT_PASS  $PW_FIFO ) &

# decrypt to temp file
ansible-vault view --vault-password-file $PW_FIFO $ENV_FILE  $TMP_ENV

# run docker-compose
docker-compose --env-file $TMP_ENV -f $COMPOSE_FILE up -d