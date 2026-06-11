#!/bin/bash

# Cores para o output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # Sem cor

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

# Reinicia e recarrega os serviços vitais de gerenciamento
recarregar_daemons() {
    echo -e "${GREEN}--> Atualizando e reiniciando Supervisor e Nginx...${NC}"
    sudo supervisorctl reread
    sudo supervisorctl update
    sudo supervisorctl restart all
    sudo systemctl restart nginx
}

# ==============================================================================
# 4) VALIDAR STATUS DOS SERVIÇOS (PORTAS)
# ==============================================================================
validar_infra() {
    echo -e "\n${YELLOW}====== Validar Status dos Serviços (Portas) ======${NC}"
    
    check_port() {
        local port=$1
        local name=$2
        if netstat -tuln | grep -q ":$port "; then
            echo -e "[ ${GREEN}OK${NC} ] Porta $port ($name) está respondendo."
        else
            echo -e "[ ${RED}FALHA${NC} ] Porta $port ($name) NÃO está ativa."
        fi
    }

    check_port 65011 "phpMyAdmin Web"
    check_port 65012 "Serviço Redis"
    check_port 65013 "Gerenciador Web do Redis"
    check_port 65014 "Painel de Impressão CUPS"
    
    echo -e "${YELLOW}--> Portas adicionais de aplicações ativas:${NC}"
    netstat -tuln | grep nginx | awk '{print $4}' | sed 's/.*://' | sort -nu | while read -r port; do
        if [ "$port" != "65011" ] && [ "$port" != "65013" ]; then
            echo -e "  [ ATIVA ] Porta Nginx: $port"
        fi
    done
    echo -e "${GREEN}=======================================================${NC}\n"
}

# ==============================================================================
# 1) INSTALAR / SOBRESCREVER AMBIENTE CORE
# ==============================================================================
instalar_infra() {
    check_root

    if [ -d "$WWW_DIR" ] || [ -d "$PROGRAMS_DIR" ]; then
        echo -e "${YELLOW}[AVISO] Já existem estruturas de pastas locais neste diretório.${NC}"
        read -p "Deseja sobrescrever as configurações existentes? (y/n): " SOBRE
        if [[ ! "$SOBRE" =~ ^[Yy]$ ]]; then
            echo -e "${RED}Operação cancelada.${NC}"
            return
        fi
    fi

    # 1. Dados de usuário unificados
    echo -e "${YELLOW}--> Configurar Usuário Administrador (MariaDB & phpMyAdmin):${NC}"
    read -p "Digite o nome do usuário: " DB_USER

    while true; do
        read -sp "Digite a senha para o usuário $DB_USER: " DB_PASS
        echo ""
        read -sp "Confirme a senha para o usuário $DB_USER: " DB_PASS_CONFIRM
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

    # Instalar PHP 8.3
    add-apt-repository ppa:ondrej/php -y
    apt update
    apt install -y php8.3-fpm php8.3-cli php8.3-mysql php8.3-curl php8.3-xml php8.3-mbstring php8.3-zip php8.3-bcmath php8.3-soap php8.3-intl php8.3-readline php8.3-redis

    # Composer
    curl -sS https://getcomposer.org/installer | php
    mv composer.phar /usr/local/bin/composer

    # MariaDB
    apt install -y mariadb-server mariadb-client
    systemctl enable --now mariadb

    # Redis
    apt install -y redis-server
    systemctl enable --now redis-server

    # Configuração de portas altas nativas
    echo -e "${GREEN}--> Modificando porta padrão do Redis para 65012...${NC}"
    sed -i 's/^port .*/port 65012/' /etc/redis/redis.conf
    systemctl restart redis-server

    # Configurando Banco de Dados com os inputs coletados
    echo -e "${GREEN}--> Criando acessos e privilégios no MariaDB...${NC}"
    mysql -e "ALTER USER 'root'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$DB_PASS');"
    mysql -e "CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASS';"
    mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$DB_USER'@'localhost' WITH GRANT OPTION;"
    mysql -e "FLUSH PRIVILEGES;"

    # Configurando phpMyAdmin de forma automatizada usando as credenciais fornecidas
    echo -e "${GREEN}--> Injetando credenciais no banco do phpMyAdmin...${NC}"
    echo "phpmyadmin phpmyadmin/dbconfig-install boolean true" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/app-password-override password $DB_PASS" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-user string $DB_USER" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/mysql/admin-pass password $DB_PASS" | debconf-set-selections
    echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect nginx" | debconf-set-selections
    apt install -y phpmyadmin

    # Organização de Pastas locais e permissões de travessia do Nginx
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

    # phpRedisAdmin
    if [ ! -d "$WWW_DIR/phpredisadmin" ]; then
        echo -e "${GREEN}--> Clonando Gerenciador Web do Redis...${NC}"
        git clone https://github.com/ErikDubbelboer/phpRedisAdmin.git "$WWW_DIR/phpredisadmin"
        cd "$WWW_DIR/phpredisadmin" && git submodule init && git submodule update
        cp includes/config.sample.inc.php includes/config.inc.php
        sed -i "s/'port' => .*/'port' => 65012,/" includes/config.inc.php
        chown -R $REAL_USER:www-data "$WWW_DIR/phpredisadmin"
        cd "$BASE_DIR"
    fi

    ln -sf /usr/share/phpmyadmin "$WWW_DIR/phpmyadmin"

    # Configuração do CUPS
    echo -e "${GREEN}--> Configurando roteamento externo do CUPS...${NC}"
    systemctl stop cups
    sed -i 's/^Listen localhost:.*/Listen *:65014/' /etc/cups/cupsd.conf
    sed -i 's/^Port .*/Port 65014/' /etc/cups/cupsd.conf
    cupsctl --remote-admin --remote-any
    systemctl start cups

    # Geração dos blocos de servidores de infraestrutura do Nginx
    echo -e "${GREEN}--> Escrevendo Virtual Hosts do Nginx...${NC}"
    tee /etc/nginx/sites-available/phpmyadmin_65011 > /dev/null <<EOF
server {
    listen 65011 default_server;
    listen [::]:65011 default_server;
    root /usr/share/phpmyadmin;
    index index.php index.html;
    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/var/run/php/php8.3-fpm.sock; }
}
EOF

    tee /etc/nginx/sites-available/phpredisadmin_65013 > /dev/null <<EOF
server {
    listen 65013;
    listen [::]:65013;
    root $WWW_DIR/phpredisadmin;
    index index.php index.html;
    location / { try_files \$uri \$uri/ =404; }
    location ~ \.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/var/run/php/php8.3-fpm.sock; }
}
EOF

    ln -sf /etc/nginx/sites-available/phpmyadmin_65011 /etc/nginx/sites-enabled/
    ln -sf /etc/nginx/sites-available/phpredisadmin_65013 /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Automatizando liberação inicial do Firewall UFW para a intranet
    echo -e "${GREEN}--> Configurando regras de Firewall (UFW) para Intranet...${NC}"
    ufw allow 65011/tcp > /dev/null
    ufw allow 65012/tcp > /dev/null
    ufw allow 65013/tcp > /dev/null
    ufw allow 65014/tcp > /dev/null
    ufw allow 80/tcp > /dev/null
    ufw reload > /dev/null

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

    if [ -f "/etc/nginx/sites-available/app_${APP_NAME}.conf" ]; then
        echo -e "${RED}[ERRO] Já existe uma configuração para o site '${APP_NAME}'.${NC}"
        return
    fi

    echo -e "${BLUE}Defina o caminho absoluto da pasta pública (onde fica o index.php ou index.html)${NC}"
    echo -e "Exemplo sugerido: ${GREEN}$WWW_DIR/seu-projeto/public${NC}"
    read -p "Digite o caminho absoluto: " APP_ROOT

    if [ ! -d "$APP_ROOT" ]; then
        echo -e "${YELLOW}[AVISO] O caminho informado não existe fisicamente. Deseja criá-lo? (y/n):${NC} " CREATE_DIR
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

    read -p "Digite a porta exclusiva da intranet para este site (ex: 8081): " APP_PORT
    if netstat -tuln | grep -q ":$APP_PORT "; then
        echo -e "${RED}[ERRO] A porta $APP_PORT já está sendo usada por outro serviço!${NC}"
        return
    fi

    # Geração dinâmica do bloco do servidor customizado
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
        fastcgi_pass unix:/var/run/php/php8.3-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }
}
EOF

    # Ativa e adiciona regra no Firewall
    ln -sf /etc/nginx/sites-available/app_${APP_NAME}.conf /etc/nginx/sites-enabled/
    ufw allow $APP_PORT/tcp > /dev/null
    ufw reload > /dev/null

    echo -e "${GREEN}--> Configuração do site '${APP_NAME}' adicionada com sucesso na porta ${APP_PORT}!${NC}"
    
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
        local porta_fw=$(grep -E 'listen [0-9]+' "/etc/nginx/sites-available/$TARGET_APP" | head -n1 | awk '{print $2}' | tr -d ';')

        read -p "Deseja remover as configurações de '$TARGET_APP'? (O código fonte NÃO será deletado) (y/n): " CONFIRM
        if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
            rm -f "/etc/nginx/sites-enabled/$TARGET_APP"
            rm -f "/etc/nginx/sites-available/$TARGET_APP"
            
            if [ ! -z "$porta_fw" ]; then
                ufw delete allow $porta_fw/tcp > /dev/null
                ufw reload > /dev/null
            fi
            
            echo -e "${GREEN}Configuração de site removida com sucesso.${NC}"
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
    echo -e "${RED}⚠️ ATENÇÃO! Isso irá remover o Nginx, PHP, MariaDB, Redis, Supervisor, phpMyAdmin e configurações de sistema.${NC}"
    read -p "Tem certeza absoluta que deseja desinstalar a infraestrutura? (y/n): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Operação cancelada.${NC}"
        return
    fi

    echo -e "${RED}--> Limpando Virtual Hosts customizados do Nginx...${NC}"
    rm -f /etc/nginx/sites-enabled/*
    rm -f /etc/nginx/sites-available/app_*
    rm -f /etc/nginx/sites-available/phpmyadmin_65011
    rm -f /etc/nginx/sites-available/phpredisadmin_65013

    echo -e "${RED}--> Purgando pacotes do sistema...${NC}"
    apt purge -y nginx nginx-common php8.3* mariadb-server mariadb-client redis-server phpmyadmin supervisor cups
    apt autoremove -y
    apt clean

    echo -e "${YELLOW}--> Os pacotes do sistema foram removidos.${NC}"
    read -p "Deseja excluir também as suas pastas locais 'www/' e 'programs/' por completo? (y/n): " DEL_FOLDERS
    if [[ "$DEL_FOLDERS" =~ ^[Yy]$ ]]; then
        rm -rf "$WWW_DIR" "$PROGRAMS_DIR"
        echo -e "${RED}Pastas locais deletadas integralmente.${NC}"
    else
        echo -e "${GREEN}--> Preservando suas aplicações web e limpando apenas os componentes da infraestrutura...${NC}"
        # Remove apenas o link simbólico do phpMyAdmin que criamos na pasta www
        rm -f "$WWW_DIR/phpmyadmin"
        
        # Remove apenas a pasta clonada do phpRedisAdmin
        if [ -d "$WWW_DIR/phpredisadmin" ]; then
            rm -rf "$WWW_DIR/phpredisadmin"
        fi
        
        echo -e "${GREEN}Suas aplicações web em '$WWW_DIR' foram mantidas intactas e limpas!${NC}"
    fi

    echo -e "${GREEN}====== Desinstalação Concluída ======${NC}"
}

# ==============================================================================
# INTERFACE PRINCIPAL (MENU DE LOOP INTERATIVO)
# ==============================================================================
while true; do
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}    Painel de Gerenciamento Avançado de Aplicações     ${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "Escolha uma das opções abaixo:"
    echo -e "1) ${GREEN}Instalar / Sobrescrever Ambiente Core${NC}"
    echo -e "2) ${BLUE}Adicionar Configuração de Site Existente${NC}"
    echo -e "3) ${RED}Remover Configuração de Site Existente${NC}"
    echo -e "4) ${YELLOW}Validar Status dos Serviços (Portas)${NC}"
    echo -e "5) Desinstalar Infraestrutura Completa"
    echo -e "6) Sair"
    echo -e "${BLUE}=======================================================${NC}"
    read -p "Digite a opção: " OPCAO

    case $OPCAO in
        1) instalar_infra ;;
        2) adicionar_app ;;
        3) remover_app ;;
        4) validar_infra ;;
        5) desinstalar_infra; break ;;
        6) exit 0 ;;
        *) echo -e "${RED}Opção inválida.${NC}\n" ;;
    esac
done