#!/bin/bash

# Cores para o output
GREEN='\033[1;32m'   # Verde claro/brilhante
RED='\033[0;31m'     # Vermelho suave (menos forte)
YELLOW='\033[0;33m'  # Amarelo suave (sem tom alaranjado)
BLUE='\033[1;36m'    # Azul ciano claro/brilhante
NC='\033[0m'         # Sem cor

# Modo não interativo para evitar prompts de senha do MariaDB durante apt
export DEBIAN_FRONTEND=noninteractive
export MYSQL_PWD=""

BASE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
WWW_DIR="$BASE_DIR/www"
PROGRAMS_DIR="$BASE_DIR/programs"

# Garante que o script roda como root quando necessário
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}[ERRO] Por favor, execute este script usando sudo!${NC}"
        exit 1
    fi
}

# Verifica e libera o lock do dpkg antes de qualquer operação com apt
liberar_lock() {
    local lock_file="/var/lib/dpkg/lock-frontend"
    local lock_file_old="/var/lib/dpkg/lock"
    local count=0
    local max_wait=30

    # Corrige dpkg interrompido antes de qualquer operação
    if dpkg --audit 2>/dev/null | grep -q .; then
        echo -e "${YELLOW}[dpkg] Estado inconsistente detectado. Executando dpkg --configure -a...${NC}"
        dpkg --configure -a 2>/dev/null
        echo -e "${GREEN}[OK] dpkg recuperado.${NC}"
    fi

    while [ -f "$lock_file" ] || [ -f "$lock_file_old" ]; do
        local pid=""
        if [ -f "$lock_file" ]; then
            pid=$(fuser "$lock_file" 2>/dev/null | awk '{print $1}')
        elif [ -f "$lock_file_old" ]; then
            pid=$(fuser "$lock_file_old" 2>/dev/null | awk '{print $1}')
        fi

        if [ -n "$pid" ]; then
            local pname=$(ps -p "$pid" -o comm= 2>/dev/null)
            echo -e "${YELLOW}[LOCK] dpkg bloqueado por processo $pid ($pname)${NC}"

            if [ "$count" -ge "$max_wait" ]; then
                echo -e "${YELLOW}Tempo esgotado. Deseja forçar a remoção do lock? (y/n):${NC} "
                read -r answer
                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    echo -e "${RED}--> Matando processo $pid ($pname)...${NC}"
                    kill -9 "$pid" 2>/dev/null
                    rm -f "$lock_file" "$lock_file_old" 2>/dev/null
                    echo -e "${GREEN}[OK] Lock removido.${NC}"
                    break
                else
                    echo -e "${RED}Operação cancelada.${NC}"
                    exit 1
                fi
            fi

            echo -e "${YELLOW}Aguardando liberação do lock (${count}s/${max_wait}s)...${NC}"
            sleep 1
            count=$((count + 1))
        else
            echo -e "${YELLOW}[LOCK] Lock órfão. Removendo...${NC}"
            rm -f "$lock_file" "$lock_file_old" 2>/dev/null
            break
        fi
    done

    if [ "$count" -gt 0 ]; then
        echo -e "${GREEN}[OK] Lock liberado após ${count}s.${NC}"
    fi
}

# Reinicia e recarrega os serviços vitais de gerenciamento
recarregar_daemons() {
    echo -e "${GREEN}--> Atualizando e reiniciando Supervisor e Nginx...${NC}"
    sudo supervisorctl reread
    sudo supervisorctl update
    sudo supervisorctl restart all
    sudo systemctl restart nginx
}

# ==============================================================================
# 4) VALIDAR STATUS DOS SERVIÇOS (PORTAS E SUPERVISOR)
# ==============================================================================
validar_infra() {
    echo -e "\n${YELLOW}====== Validar Status dos Serviços (Portas) ======${NC}"
    
    check_port() {
        local port=$1
        local name=$2
        if netstat -tuln | grep -q ":$port "; then
            echo -e "[ ${GREEN}OK${NC} ] Porta $port ($name) está respondendo."
        else
            echo -e "[ ${RED}FALHA${NC} ] Porta $port ($name) NÃO está activa."
        fi
    }

    check_port 65011 "phpMyAdmin Web"
    check_port 65014 "Painel de Impressão CUPS"

    # Tenta iniciar o CUPS se não estiver respondendo na porta
    if ! netstat -tuln 2>/dev/null | grep -q ":65014 "; then
        if systemctl is-active --quiet cups 2>/dev/null; then
            echo -e "${YELLOW}-> CUPS ativo mas não na porta 65014. Verificando config...${NC}"
        else
            echo -e "${YELLOW}-> CUPS parado. Tentando iniciar...${NC}"
            systemctl start cups
            sleep 2
            if systemctl is-active --quiet cups; then
                echo -e "[ ${GREEN}OK${NC} ] CUPS iniciado com sucesso."
            else
                echo -e "[ ${RED}FALHA${NC} ] Não foi possível iniciar o CUPS."
                echo -e "  Verifique: ${YELLOW}journalctl -u cups --no-pager | tail -20${NC}"
            fi
        fi
    fi
    
    echo -e "${YELLOW}--> Portas adicionais de aplicações ativas (Nginx/Reverb/Sites):${NC}"
    netstat -tuln | grep -E 'nginx|php|artisan' | awk '{print $4}' | sed 's/.*://' | sort -nu | while read -r port; do
        if [ "$port" != "65011" ]; then
            echo -e "  [ ATIVA ] Porta ativa no sistema: $port"
        fi
    done

    echo -e "\n${YELLOW}--> Status dos Processos no Supervisor:${NC}"
    sudo supervisorctl status

    # Validação da impressora HyperViewerPrinter
    echo -e "\n${YELLOW}--> Status da Impressora Virtual HyperViewerPrinter:${NC}"
    local lp_out
    lp_out=$(lpstat -p HyperViewerPrinter 2>&1)
    if echo "$lp_out" | grep -qi "printer HyperViewerPrinter\|impressora HyperViewerPrinter"; then
        echo -e "[ ${GREEN}OK${NC} ] Impressora HyperViewerPrinter está instalada."
        echo "$lp_out" | head -3
    else
        echo -e "[ ${RED}AUSENTE${NC} ] Impressora HyperViewerPrinter não encontrada."
        echo -e "  Execute a opção 6 do menu ou rode: ${YELLOW}sudo bash $WWW_DIR/HyperViewer/scripts/install_printer.sh${NC}"
        echo -e "  Saída do lpstat: $lp_out"
    fi
    
    echo -e "${GREEN}=======================================================${NC}\n"
}

# ==============================================================================
# 1) INSTALAR / SOBRESCREVER AMBIENTE CORE
# ==============================================================================
instalar_infra() {
    check_root
    liberar_lock

    if [ -d "$WWW_DIR" ] || [ -d "$PROGRAMS_DIR" ]; then
        echo -e "${YELLOW}[AVISO] Já existem estruturas de pastas locais neste diretório.${NC}"
        read -p "Deseja sobrescrever as configurações existentes? (y/n): " SOBRE
        if [[ ! "$SOBRE" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Operação cancelada.${NC}"
            return
        fi
    fi

    # 1. Dados de usuário unificados (Simplificado para apenas Root)
    echo -e "${YELLOW}--> Configurar Senha do Usuário root (MariaDB & phpMyAdmin):${NC}"
    while true; do
        read -sp "Digite a senha unificada: " DB_PASS
        echo ""
        read -sp "Confirme a senha unificada: " DB_PASS_CONFIRM
        echo ""
        
        if [ "$DB_PASS" = "$DB_PASS_CONFIRM" ]; then
            echo -e "${GREEN}Senhas conferem! Iniciando instalação...${NC}\n"
            break
        else
            echo -e "${RED}As senhas não coincidem. Tente novamente.${NC}\n"
        fi
    done

    # 2. Instalação de pacotes
    echo -e "${GREEN}--> Atualizando repositórios e instalando dependências...${NC}"
    apt update && apt upgrade -y
    apt install -y software-properties-common curl unzip git ufw net-tools cups supervisor nginx

    # Instalar PHP 8.5 e Extensões necessárias
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y php8.5-fpm php8.5-cli php8.5-mysql php8.5-curl php8.5-xml \
    php8.5-mbstring php8.5-zip php8.5-bcmath php8.5-soap php8.5-intl \
    php8.5-readline php8.5-gd php8.5-snmp php8.5-sqlite3 php8.5-imagick \
    ghostscript

    # Garante que a função exec() não está desabilitada (necessária para o sistema)
    PHP_INI_CLI=$(php8.5 --ini | grep "Loaded Configuration" | head -1 | awk '{print $NF}')
    PHP_INI_FPM="/etc/php/8.5/fpm/php.ini"
    for ini in "$PHP_INI_CLI" "$PHP_INI_FPM"; do
        if [ -f "$ini" ]; then
            sed -i 's/^disable_functions =.*/disable_functions = /' "$ini"
            echo -e "${GREEN}[OK] exec() habilitada em $ini${NC}"
        fi
    done

    # Composer
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer

    # MariaDB - pré-configura a senha root para evitar prompt interativo
    echo -e "${GREEN}--> Pré-configurando senha do MariaDB...${NC}"
    debconf-set-selections <<< "mariadb-server mariadb-server/root_password password $DB_PASS"
    debconf-set-selections <<< "mariadb-server mariadb-server/root_password_again password $DB_PASS"

    apt install -y mariadb-server mariadb-client
    systemctl enable --now mariadb

    # Aguarda o MariaDB ficar pronto
    sleep 2

    # Configurando Banco de Dados usando o usuário ROOT nativo por senha pura
    echo -e "${GREEN}--> Alterando credenciais do usuário 'root' no MariaDB...${NC}"
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING '$DB_PASS';"
    mysql -e "FLUSH PRIVILEGES;"

    # Atualiza a variável MYSQL_PWD para comandos futuros
    export MYSQL_PWD="$DB_PASS"

    # [SIMPLIFICAÇÃO] Ignorando o banco interno do phpMyAdmin e instalando direto sem dependências extras
    echo -e "${GREEN}--> Configurando instalador do phpMyAdmin de forma limpa...${NC}"
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect nginx" | debconf-set-selections
    
    echo -e "${GREEN}--> Instalando phpMyAdmin...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold" phpmyadmin

    # [SIMPLIFICAÇÃO CHAVE] Força o phpMyAdmin a usar autenticação tradicional por cookie para entrar como root
    echo -e "${GREEN}--> Ajustando arquivo de configuração do phpMyAdmin para autenticação Direta (root)...${NC}"
    if [ -f /etc/phpmyadmin/config.inc.php ]; then
        # Garante que o modo de autenticação é 'cookie' para o formulário manual funcionar
        sed -i "s/\$cfg\['Servers'\]\[\$i\]\['auth_type'\] = .*/\$cfg\['Servers'\]\[\$i\]\['auth_type'\] = 'cookie';/" /etc/phpmyadmin/config.inc.php
        # Remove restrições nativas que impedem o Root de logar sem senha via Web
        sed -i "s/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = .*/\$cfg\['Servers'\]\[\$i\]\['AllowNoPassword'\] = false;/" /etc/phpmyadmin/config.inc.php
    fi

    # Organização de Pastas locais e permissões
    mkdir -p "$WWW_DIR" "$PROGRAMS_DIR"
    REAL_USER=${SUDO_USER:-$USER}
    REAL_HOME=$(eval echo ~$REAL_USER)

    CURRENT_PATH="$BASE_DIR"
    while [ "$CURRENT_PATH" != "$REAL_HOME" ] && [ "$CURRENT_PATH" != "/" ]; do
        chmod +x "$CURRENT_PATH"
        CURRENT_PATH=$(dirname "$CURRENT_PATH")
    done
    chmod +x "$REAL_HOME"

    chown -R $REAL_USER:www-data "$WWW_DIR"
    chmod -R 775 "$WWW_DIR"
    chown -R $REAL_USER:$REAL_USER "$PROGRAMS_DIR"

    ln -sf /usr/share/phpmyadmin "$WWW_DIR/phpmyadmin"

    # Configuração do CUPS
    echo -e "${GREEN}--> Instalando printer-driver-cups-pdf e ghostscript para impressão virtual PDF...${NC}"
    apt install -y cups printer-driver-cups-pdf ghostscript

    echo -e "${GREEN}--> Configurando roteamento e acessos irrestritos do CUPS...${NC}"
    systemctl stop cups
    sed -i 's/^Listen localhost:.*/Listen *:65014/' /etc/cups/cupsd.conf
    sed -i 's/^Port .*/Port 65014/' /etc/cups/cupsd.conf
    
    sed -i '/<\/VisualAuthentication>/a DefaultEncryption Never' /etc/cups/cupsd.conf
    sed -i 's/<Location \/>/<Location \/>\n  Order allow,deny\n  Allow all/' /etc/cups/cupsd.conf
    sed -i 's/<Location \/admin>/<Location \/admin>\n  Order allow,deny\n  Allow all/' /etc/cups/cupsd.conf
    
    systemctl start cups
    
    # cupsctl precisa do CUPS rodando
    sleep 2

    # Verifica se o CUPS realmente iniciou
    if ! systemctl is-active --quiet cups; then
        echo -e "${YELLOW}[AVISO] CUPS não iniciou na primeira tentativa. Tentando novamente...${NC}"
        systemctl start cups
        sleep 2
        if ! systemctl is-active --quiet cups; then
            echo -e "${RED}[ERRO] CUPS não conseguiu iniciar. Verifique o log: journalctl -u cups${NC}"
        fi
    fi

    cupsctl --remote-admin --remote-any --share-printers

    # Instala a impressora virtual HyperViewerPrinter
    PRINTER_SCRIPT="$WWW_DIR/HyperViewer/scripts/install_printer.sh"
    if [ -f "$PRINTER_SCRIPT" ]; then
        echo -e "${GREEN}--> Instalando impressora virtual HyperViewerPrinter...${NC}"
        bash "$PRINTER_SCRIPT"
    else
        echo -e "${YELLOW}[AVISO] Script install_printer.sh não encontrado em $PRINTER_SCRIPT.${NC}"
        echo -e "${YELLOW}Para instalar manualmente, execute: sudo bash $WWW_DIR/HyperViewer/scripts/install_printer.sh${NC}"
    fi

    # Gera o config.json se não existir (necessário para o instalador web)
    CONFIG_JSON="$WWW_DIR/HyperViewer/src/config.json"
    if [ ! -f "$CONFIG_JSON" ]; then
        echo -e "${GREEN}--> Gerando config.json padrão...${NC}"
        LOCAL_IP=$(hostname -I 2>/dev/null | awk '{print $1}')
        [ -z "$LOCAL_IP" ] && LOCAL_IP="127.0.0.1"
        cat > "$CONFIG_JSON" <<EOF
{
    "port": "65000",
    "ip": {
        "value": "${LOCAL_IP}"
    }
}
EOF
        echo -e "${GREEN}[OK] config.json criado em $CONFIG_JSON${NC}"
    fi

    # Geração dos blocos Nginx Core
    echo -e "${GREEN}--> Escrevendo Virtual Hosts do Nginx...${NC}"
    tee /etc/nginx/sites-available/phpmyadmin_65011 > /dev/null <<EOF
server {
    listen 65011 default_server;
    listen [::]:65011 default_server;
    root /usr/share/phpmyadmin;
    index index.php index.html;
    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/var/run/php/php8.5-fpm.sock; }
}
EOF

    ln -sf /etc/nginx/sites-available/phpmyadmin_65011 /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Firewall UFW
    echo -e "${GREEN}--> Configurando regras de Firewall (UFW) para Intranet...${NC}"
    ufw allow 65011/tcp > /dev/null
    ufw allow 65014/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw reload > /dev/null

    systemctl restart php8.5-fpm
    recarregar_daemons
    validar_infra
}

# ==============================================================================
# 2) ADICIONAR CONFIGURAÇÃO DE SITE EXISTENTE
# ==============================================================================
adicionar_app() {
    check_root
    echo -e "${YELLOW}====== Adicionar Configuração de Site Existente ======${NC}"
    
    read -p "Digite o nome do site (ex: laravel-app): " APP_NAME
    APP_NAME=$(echo "$APP_NAME" | sed 's/[^a-zA-Z0-9_-]//g')

    # Variável para controlar se é uma reconfiguração/sobrescrita
    local SOBRE_APP="n"

    if [ -f "/etc/nginx/sites-available/app_${APP_NAME}.conf" ]; then
        echo -e "${YELLOW}[AVISO] Já existe uma configuração para o site '${APP_NAME}'.${NC}"
        read -p "Deseja sobrescrever a configuração existente? (y/n): " SOBRE_APP
        if [[ ! "$SOBRE_APP" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Operação cancelada.${NC}"
            return
        fi
        rm -f "/etc/nginx/sites-enabled/app_${APP_NAME}.conf"
        SOBRE_APP="y"
    fi

    echo -e "${BLUE}Defina o caminho da pasta pública (onde fica o index.php ou index.html)${NC}"
    echo -e "O caminho base atual é: ${GREEN}$WWW_DIR/${NC}"
    read -p "Complete o caminho (ex: HyperViewer/src/public): " APP_SUBPATH

    if [[ "$APP_SUBPATH" =~ ^/ ]]; then
        APP_ROOT="$APP_SUBPATH"
    else
        APP_ROOT="$WWW_DIR/$APP_SUBPATH"
    fi

    if [ ! -d "$APP_ROOT" ]; then
        echo -e "${YELLOW}[AVISO] O caminho informado ($APP_ROOT) não existe. Deseja criá-lo? (y/n):${NC} " CREATE_DIR
        if [[ "$CREATE_DIR" =~ ^[Yy]$ ]]; then
            mkdir -p "$APP_ROOT"
            REAL_USER=${SUDO_USER:-$USER}
            chown -R $REAL_USER:www-data $(dirname "$APP_ROOT")
            chmod -R 775 $(dirname "$APP_ROOT")
        else
            echo -e "${RED}Operação cancelada. Caminho inválido.${NC}"
            return
        fi
    fi

    # Caminho raiz do projeto Laravel
    LARAVEL_ROOT=$(dirname "$APP_ROOT")
    REAL_USER=${SUDO_USER:-$USER}

    # --------------------------------------------------------------------------
    # ESTEIRA DE AUTOMAÇÃO/INICIALIZAÇÃO DO LARAVEL
    # --------------------------------------------------------------------------
    if [ -f "$LARAVEL_ROOT/artisan" ]; then
        echo -e "${GREEN}--> Estrutura do Laravel detectada em: $LARAVEL_ROOT${NC}"
        
        # 1. Copiar ou Criar o arquivo .env
        if [ ! -f "$LARAVEL_ROOT/.env" ]; then
            if [ -f "$LARAVEL_ROOT/.env.example" ]; then
                echo -e "${YELLOW}[AVISO] Arquivo .env ausente. Copiando do .env.example...${NC}"
                sudo -u $REAL_USER cp "$LARAVEL_ROOT/.env.example" "$LARAVEL_ROOT/.env"
            else
                echo -e "${YELLOW}[AVISO] Nenhum .env ou .env.example encontrado. Criando um modelo básico...${NC}"
                sudo -u $REAL_USER tee "$LARAVEL_ROOT/.env" > /dev/null <<EOF
APP_NAME=$APP_NAME
APP_ENV=local
APP_KEY=
APP_DEBUG=true
APP_URL=http://localhost
EOF
            fi
        fi

        # 2. Instalação do Composer (se a pasta vendor não existir)
        if [ ! -d "$LARAVEL_ROOT/vendor" ]; then
            echo -e "${YELLOW}[AVISO] A pasta 'vendor/' (dependências) está ausente.${NC}"
            read -p "Deseja rodar 'composer install' agora? (y/n): " RUN_COMPOSER
            if [[ "$RUN_COMPOSER" =~ ^[Yy]$ ]]; then
                echo -e "Escolha o tipo de ambiente para instalação:"
                echo -e "1) ${BLUE}Desenvolvimento (Instala pacotes dev e debug)${NC}"
                echo -e "2) ${GREEN}Produção (Mais rápido, limpo, ignora require-dev)${NC}"
                read -p "Selecione o número (1 ou 2): " COMPOSER_ENV
                
                echo -e "${GREEN}--> Executando composer install...${NC}"
                
                if [ "$COMPOSER_ENV" = "2" ]; then
                    (cd "$LARAVEL_ROOT" && sudo -u $REAL_USER php8.5 /usr/local/bin/composer install --no-dev --optimize-autoloader)
                else
                    (cd "$LARAVEL_ROOT" && sudo -u $REAL_USER php8.5 /usr/local/bin/composer install)
                fi
            fi
        fi

        # Garante a criação prévia de pastas críticas de escrita para evitar erros nos comandos artisan
        mkdir -p "$LARAVEL_ROOT/storage/logs" "$LARAVEL_ROOT/storage/framework/cache" "$LARAVEL_ROOT/storage/framework/sessions" "$LARAVEL_ROOT/storage/framework/views" "$LARAVEL_ROOT/bootstrap/cache"
        chown -R $REAL_USER:www-data "$LARAVEL_ROOT"
        chmod -R 775 "$LARAVEL_ROOT/storage" "$LARAVEL_ROOT/bootstrap/cache"

        # 3. Gerar Chave da Aplicação (se necessário)
        if grep -q "APP_KEY=$" "$LARAVEL_ROOT/.env" || grep -q "APP_KEY= " "$LARAVEL_ROOT/.env" || ! grep -q "APP_KEY=" "$LARAVEL_ROOT/.env"; then
            echo -e "${GREEN}--> Gerando chave única da aplicação (artisan key:generate)...${NC}"
            sudo -u $REAL_USER php8.5 "$LARAVEL_ROOT/artisan" key:generate
        fi

        # 4. Executar Migrations e Seeds
        read -p "Deseja rodar as Migrations com Seeds agora? (php artisan migrate --seed)? (y/n): " RUN_MIGRATE
        if [[ "$RUN_MIGRATE" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}--> Executando migrações de banco de dados...${NC}"
            sudo -u $REAL_USER php8.5 "$LARAVEL_ROOT/artisan" migrate --seed
        fi

        # 5. Otimizar e Limpar Caches
        echo -e "${GREEN}--> Limpando e otimizando caches do Laravel (artisan optimize:clear)...${NC}"
        sudo -u $REAL_USER php8.5 "$LARAVEL_ROOT/artisan" optimize:clear
    fi

    # Validação de Porta do Servidor Nginx
    read -p "Digite a porta exclusiva da intranet para este site (ex: 8081): " APP_PORT
    if [ "$SOBRE_APP" != "y" ]; then
        if netstat -tuln | grep -q ":$APP_PORT "; then
            echo -e "${RED}[ERRO] A porta $APP_PORT já está sendo usada por outro serviço!${NC}"
            return
        fi
    fi

    # Geração dinâmica do bloco do servidor customizado no Nginx
    sudo tee /etc/nginx/sites-available/app_${APP_NAME}.conf > /dev/null <<EOF
server {
    listen $APP_PORT;
    listen [::]:$APP_PORT;
    root $APP_ROOT;
    index index.php index.html index.htm;
    server_name _;
    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.5-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/app_${APP_NAME}.conf /etc/nginx/sites-enabled/
    ufw allow $APP_PORT/tcp > /dev/null
    ufw reload > /dev/null

    # --------------------------------------------------------------------------
    # AUTOMAÇÃO DO SUPERVISOR PARA DAEMONS DO LARAVEL
    # --------------------------------------------------------------------------
    if [ -f "$LARAVEL_ROOT/artisan" ]; then
        read -p "Este site precisa de Daemons ativos em Background no Supervisor (Queue/Scheduler/Reverb)? (y/n): " IS_LARAVEL
        if [[ "$IS_LARAVEL" =~ ^[Yy]$ ]]; then
            echo -e "${GREEN}--> Configurando Daemons do Supervisor para o Laravel...${NC}"
            
            read -p "Digite a porta exclusiva para o Laravel Reverb (Pressione ENTER para o padrão 65010): " REVERB_PORT
            if [ -z "$REVERB_PORT" ]; then
                REVERB_PORT="65010"
            fi

            ufw allow $REVERB_PORT/tcp > /dev/null
            ufw reload > /dev/null

            sudo tee /etc/supervisor/conf.d/laravel_${APP_NAME}.conf > /dev/null <<EOF
[program:laravel_queue_${APP_NAME}]
process_name=%(program_name)s_%(process_num)02d
command=php8.5 $LARAVEL_ROOT/artisan queue:work --sleep=2 --timeout=0 --tries=3
directory=$LARAVEL_ROOT
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
user=$REAL_USER
numprocs=1
redirect_stderr=true
stdout_logfile=$LARAVEL_ROOT/storage/logs/queue_worker.log
stdout_logfile_maxbytes=10MB

[program:laravel_scheduler_${APP_NAME}]
command=php8.5 $LARAVEL_ROOT/artisan schedule:work
directory=$LARAVEL_ROOT
autostart=true
autorestart=true
user=$REAL_USER
redirect_stderr=true
stdout_logfile=$LARAVEL_ROOT/storage/logs/scheduler.log
stdout_logfile_maxbytes=5MB

[program:laravel_reverb_${APP_NAME}]
command=php8.5 $LARAVEL_ROOT/artisan reverb:start --host=0.0.0.0 --port=$REVERB_PORT
directory=$LARAVEL_ROOT
autostart=true
autorestart=true
user=$REAL_USER
redirect_stderr=true
stdout_logfile=$LARAVEL_ROOT/storage/logs/reverb.log
stdout_logfile_maxbytes=10MB
EOF
            echo -e "${GREEN}--> Arquivo de configuração do Supervisor criado com sucesso (Reverb na porta: $REVERB_PORT).${NC}"
        fi
    fi

    echo -e "${GREEN}--> Configuração do site '${APP_NAME}' adicionada na porta ${APP_PORT}!${NC}"
    recarregar_daemons
}

# ==============================================================================
# 3) REMOVER CONFIGURAÇÃO DE SITE EXISTENTE
# ==============================================================================
remover_app() {
    check_root
    echo -e "${YELLOW}====== Remover Configuração de Site Existente ======${NC}"
    
    IFS=$'\n' apps=($(ls /etc/nginx/sites-available/ | grep -E '^app_.*\.conf$'))
    
    if [ ${#apps[@]} -eq 0 ]; then
        echo -e "${YELLOW}Nenhuma configuração de site customizada encontrada para exclusão.${NC}"
        return
    fi

    echo -e "Selecione o número do site que deseja remover:"
    for i in "${!apps[@]}"; do
        local porta=$(grep -E 'listen [0-9]+' "/etc/nginx/sites-available/${apps[$i]}" | head -n1 | awk '{print $2}' | tr -d ';')
        echo -e "$((i+1))) ${apps[$i]} (Porta: $porta)"
    done
    
    read -p "Digite a opção: " SELECAO
    INDEX=$((SELECAO-1))

    if [ "$INDEX" -ge 0 ] && [ "$INDEX" -lt ${#apps[@]} ]; then
        TARGET_APP="${apps[$INDEX]}"
        CLEAN_APP_NAME=$(echo "$TARGET_APP" | sed 's/^app_//' | sed 's/\.conf$//')
        local porta_fw=$(grep -E 'listen [0-9]+' "/etc/nginx/sites-available/$TARGET_APP" | head -n1 | awk '{print $2}' | tr -d ';')

        read -p "Deseja remover as configurações de '$TARGET_APP' e seus daemons atrelados? (y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            rm -f "/etc/nginx/sites-enabled/$TARGET_APP"
            rm -f "/etc/nginx/sites-available/$TARGET_APP"
            
            if [ -f "/etc/supervisor/conf.d/laravel_${CLEAN_APP_NAME}.conf" ]; then
                echo -e "${RED}--> Removendo daemons do Supervisor...${NC}"
                local reverb_fw_port=$(grep -E '--port=[0-9]+' "/etc/supervisor/conf.d/laravel_${CLEAN_APP_NAME}.conf" | head -n1 | awk -F'--port=' '{print $2}' | awk '{print $1}')
                
                sudo supervisorctl stop "laravel_queue_${CLEAN_APP_NAME}:*" >/dev/null 2>&1
                sudo supervisorctl stop "laravel_scheduler_${CLEAN_APP_NAME}" >/dev/null 2>&1
                sudo supervisorctl stop "laravel_reverb_${CLEAN_APP_NAME}" >/dev/null 2>&1
                rm -f "/etc/supervisor/conf.d/laravel_${CLEAN_APP_NAME}.conf"
                
                if [ ! -z "$reverb_fw_port" ]; then
                    ufw delete allow $reverb_fw_port/tcp > /dev/null
                fi
            fi

            if [ ! -z "$porta_fw" ]; then
                ufw delete allow $porta_fw/tcp > /dev/null
                ufw reload > /dev/null
            fi
            
            echo -e "${GREEN}Configuração de site e serviços removidos com sucesso.${NC}"
            recarregar_daemons
        fi
    else
        echo -e "${RED}Opção inválida.${NC}"
    fi
}

# ==============================================================================
# 5) DESINSTALAR INFRAESTRUTURA COMPLETA
# ==============================================================================
desinstalar_infra() {
    check_root
    liberar_lock
    echo -e "${RED}⚠️ ATENÇÃO! Isso irá remover o Nginx, PHP, MariaDB, Supervisor, phpMyAdmin e configurações de sistema.${NC}"
    read -p "Tem certeza absoluta que deseja desinstalar a infraestrutura? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Operação cancelada.${NC}"
        return
    fi

    echo -e "${RED}--> Limpando Virtual Hosts customizados do Nginx e rotinas do Supervisor...${NC}"
    rm -f /etc/nginx/sites-enabled/*
    rm -f /etc/nginx/sites-available/app_*
    rm -f /etc/nginx/sites-available/phpmyadmin_65011
    rm -f /etc/supervisor/conf.d/*

    echo -e "${RED}--> Automatizando respostas do debconf para remoção silenciosa...${NC}"
    echo "phpmyadmin phpmyadmin/purge boolean false" | debconf-set-selections
    echo "dbconfig-common dbconfig-common/purge boolean false" | debconf-set-selections

    echo -e "${RED}--> Purgando pacotes do sistema de forma 100% silenciosa...${NC}"
    apt-get purge -y -q \
        nginx nginx-common \
        php8.5-fpm php8.5-cli php8.5-mysql php8.5-curl php8.5-xml \
        php8.5-mbstring php8.5-zip php8.5-bcmath php8.5-soap php8.5-intl \
        php8.5-readline php8.5-gd php8.5-snmp php8.5-sqlite3 php8.5-imagick \
        mariadb-server mariadb-client \
        phpmyadmin supervisor cups cups-pdf cups-client \
        ghostscript dbconfig-common 2>/dev/null
    apt-get autoremove -y -q 2>/dev/null
    apt-get clean -q 2>/dev/null

    echo -e "${YELLOW}--> Os pacotes do sistema foram removidos.${NC}"
    read -p "Deseja excluir também as suas pastas locais 'www/' e 'programs/' por completo? (y/n): " DEL_FOLDERS
    if [[ "$DEL_FOLDERS" =~ ^[Yy]$ ]]; then
        rm -rf "$WWW_DIR" "$PROGRAMS_DIR"
        echo -e "${RED}Pastas locais deletadas integralmente.${NC}"
    else
        echo -e "${GREEN}--> Preservando suas aplicações web e limpando apenas os componentes da infraestrutura...${NC}"
        rm -f "$WWW_DIR/phpmyadmin"
        echo -e "${GREEN}Suas aplicações web em '$WWW_DIR' foram mantidas intactas e limpas!${NC}"
    fi

    echo -e "${GREEN}====== Desinstalação Concluída ======${NC}"
}

# ==============================================================================
# 6) ATUALIZAR AMBIENTE CORE (APT APENAS, SEM SOBRESCREVER CONFIG)
# ==============================================================================
atualizar_infra() {
    check_root
    liberar_lock

    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}      Atualização do Ambiente Core (Apenas Pacotes)    ${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${YELLOW}Esta operação apenas atualiza os pacotes do sistema.${NC}"
    echo -e "${YELLOW}Nenhuma configuração existente será sobrescrita.${NC}\n"

    read -p "Deseja continuar com a atualização? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Operação cancelada.${NC}"
        return
    fi

    echo -e "${GREEN}--> Atualizando lista de repositórios...${NC}"
    apt update

    echo -e "\n${GREEN}--> Atualizando pacotes do sistema...${NC}"
    apt upgrade -y

    echo -e "\n${GREEN}--> Atualizando PHP e extensões...${NC}"
    apt install -y --only-upgrade php8.5-fpm php8.5-cli php8.5-mysql php8.5-curl php8.5-xml \
        php8.5-mbstring php8.5-zip php8.5-bcmath php8.5-soap php8.5-intl \
        php8.5-readline php8.5-gd php8.5-snmp php8.5-sqlite3 php8.5-imagick

    echo -e "\n${GREEN}--> Atualizando CUPS e dependências...${NC}"
    apt install -y --only-upgrade cups printer-driver-cups-pdf cups-client ghostscript

    echo -e "\n${GREEN}--> Limpando pacotes obsoletos...${NC}"
    apt autoremove -y
    apt autoclean

    echo -e "\n${GREEN}--> Reiniciando serviços...${NC}"
    systemctl restart cups

    echo -e "\n${GREEN}====== Atualização Concluída ======${NC}"
}

# ==============================================================================
# 7) DESINSTALAR IMPRESSORA HyperViewerPrinter
# ==============================================================================
desinstalar_impressora() {
    check_root

    local PRINTER_NAME="HyperViewerPrinter"
    local PPD_FILE="/etc/cups/ppd/${PRINTER_NAME}.ppd"

    echo -e "${RED}=======================================================${NC}"
    echo -e "${RED}   Desinstalação da Impressora HyperViewerPrinter      ${NC}"
    echo -e "${RED}=======================================================${NC}"

    # Verifica múltiplas formas de detectar a impressora
    local printer_found=false
    if lpstat -p "$PRINTER_NAME" 2>/dev/null | grep -qi "printer $PRINTER_NAME\|impressora $PRINTER_NAME"; then
        printer_found=true
    elif [ -f "$PPD_FILE" ]; then
        echo -e "${YELLOW}-> PPD encontrado em $PPD_FILE (CUPS pode estar offline)${NC}"
        printer_found=true
    elif grep -q "^<Printer $PRINTER_NAME>" /etc/cups/printers.conf 2>/dev/null; then
        echo -e "${YELLOW}-> Impressora encontrada no /etc/cups/printers.conf${NC}"
        printer_found=true
    fi

    if ! $printer_found; then
        echo -e "${YELLOW}Impressora '$PRINTER_NAME' não encontrada (verificado via lpstat, PPD e printers.conf).${NC}"
        return
    fi

    read -p "Tem certeza que deseja remover a impressora '$PRINTER_NAME'? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Operação cancelada.${NC}"
        return
    fi

    echo -e "${RED}--> Cancelando trabalhos pendentes...${NC}"
    cancel -a "$PRINTER_NAME" 2>/dev/null

    echo -e "${RED}--> Desabilitando impressora...${NC}"
    cupsdisable "$PRINTER_NAME" 2>/dev/null

    echo -e "${RED}--> Removendo impressora do CUPS...${NC}"
    lpadmin -x "$PRINTER_NAME" 2>/dev/null

    echo -e "${RED}--> Removendo arquivo PPD...${NC}"
    rm -f "/etc/cups/ppd/${PRINTER_NAME}.ppd"

    echo -e "${RED}--> Restaurando configuração original do cups-pdf...${NC}"
    if [ -f /etc/cups/cups-pdf.conf ]; then
        rm -f /etc/cups/cups-pdf.conf
    fi

    echo -e "\n${GREEN}[OK] Impressora '$PRINTER_NAME' desinstalada com sucesso!${NC}"
    echo -e "${YELLOW}Recomenda-se reiniciar o CUPS:${NC}"
    echo -e "  sudo systemctl restart cups\n"
}

# ==============================================================================
# INTERFACE PRINCIPAL (MENU DE LOOP INTERATIVO)
# ==============================================================================
while true; do
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}    Painel de Gerenciamento Avançado de Aplicações     ${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo -e ""
    echo -e "${GREEN}--- Ambiente Core ---${NC}"
    echo -e "1) ${GREEN}Instalar / Sobrescrever Ambiente Core${NC}"
    echo -e "2) ${GREEN}Atualizar Ambiente Core (Apenas Pacotes)${NC}"
    echo -e "3) ${RED}Desinstalar Infraestrutura Completa${NC}"
    echo -e ""
    echo -e "${BLUE}--- Sites / Aplicações ---${NC}"
    echo -e "4) ${BLUE}Adicionar Configuração de Site Existente${NC}"
    echo -e "5) ${RED}Remover Configuração de Site Existente${NC}"
    echo -e ""
    echo -e "${YELLOW}--- Impressora Virtual HyperViewerPrinter ---${NC}"
    echo -e "6) ${YELLOW}Instalar / Reconfigurar Impressora${NC}"
    echo -e "7) ${RED}Desinstalar Impressora${NC}"
    echo -e ""
    echo -e "${NC}--- Utilitários ---${NC}"
    echo -e "8) ${YELLOW}Validar Status dos Serviços (Portas & Supervisor)${NC}"
    echo -e "9) Sair"
    echo -e "${BLUE}=======================================================${NC}"
    read -p "Digite a opção: " OPCAO

    case $OPCAO in
        1)
            instalar_infra
            ;;
        2)
            atualizar_infra
            ;;
        3)
            desinstalar_infra
            break
            ;;
        4)
            adicionar_app
            ;;
        5)
            remover_app
            ;;
        6)
            PRINTER_SCRIPT="$WWW_DIR/HyperViewer/scripts/install_printer.sh"
            if [ -f "$PRINTER_SCRIPT" ]; then
                echo -e "${GREEN}--> Instalando/Reconfigurando impressora HyperViewerPrinter...${NC}"
                bash "$PRINTER_SCRIPT"
            else
                echo -e "${RED}[ERRO] Script install_printer.sh não encontrado em $PRINTER_SCRIPT.${NC}"
            fi
            ;;
        7)
            desinstalar_impressora
            ;;
        8)
            validar_infra
            ;;
        9)
            exit 0
            ;;
        *)
            echo -e "${RED}Opção inválida.${NC}\n"
            ;;
    esac
done