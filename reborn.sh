#!/bin/bash
#
# Script "Tudo-em-Um" para Gestão e Implementação do Vitalia Reborn MUD
# Nome: reborn.sh
#

set -e  # Parar o script em caso de erro

# --- ANCORAGEM DO SCRIPT ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
cd "$SCRIPT_DIR"

# --- Configurações ---
REPO_URL="https://github.com/Forneck/vitalia-reborn"
REPO_BRANCH="master"
PROJECT_DIR="vitalia-reborn"
BACKUP_DIR="backups"
VERSION_FILE=".version"
DOCKER_IMAGE="vitalia-reborn"

# --- Cores para output ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# --- Funções auxiliares ---
log_info( ) { echo -e "${BLUE}ℹ${NC} $1"; }
log_success() { echo -e "${GREEN}✅${NC} $1"; }
log_warning() { echo -e "${YELLOW}⚠️${NC} $1"; }
log_error() { echo -e "${RED}❌${NC} $1"; }

# --- Funções do Script ---

# --- FUNÇÃO CORRIGIDA ---
check_dependencies() {
    log_info "Verificando dependências (git, docker, zip, unzip)..."
    local missing_deps=()
    command -v git >/dev/null 2>&1 || missing_deps+=("git")
    command -v docker >/dev/null 2>&1 || missing_deps+=("docker")
    command -v zip >/dev/null 2>&1 || missing_deps+=("zip")
    command -v unzip >/dev/null 2>&1 || missing_deps+=("unzip")

    if [ ${#missing_deps[@]} -ne 0 ]; then
        log_error "Dependências faltando: ${missing_deps[*]}"
        log_info "Para instalar, execute: sudo apt-get update && sudo apt-get install -y ${missing_deps[*]}"
        exit 1
    fi
    log_success "Dependências verificadas."
}
# --- FIM DA CORREÇÃO ---

check_for_updates() {
    log_info "Verificando atualizações no repositório..."
    local remote_commit=$(git ls-remote "$REPO_URL" "$REPO_BRANCH" | awk '{print $1}')
    local local_commit=$([ -f "$VERSION_FILE" ] && cat "$VERSION_FILE" || echo "none")
    
    if [ "$remote_commit" = "$local_commit" ]; then
        log_success "Você já está na versão mais recente."
        return 1
    else
        log_warning "Nova versão disponível! Iniciando atualização..."
        return 0
    fi
}

download_and_preserve() {
    local temp_data_dir_name=".data_backup_$$"
    local temp_data_dir="$SCRIPT_DIR/$temp_data_dir_name"

    if [ -d "$PROJECT_DIR" ]; then
        log_info "Preservando dados de jogadores e do mundo..."
        mkdir -p "$temp_data_dir"
        [ -d "$PROJECT_DIR/lib" ] && mv "$PROJECT_DIR/lib" "$temp_data_dir/"
        rm -rf "$PROJECT_DIR"
    fi

    log_info "Baixando código fonte do GitHub..."
    git clone --depth 1 --branch "$REPO_BRANCH" "$REPO_URL" "$PROJECT_DIR"
    log_success "Código fonte baixado com sucesso."

    if [ -d "$temp_data_dir" ]; then
        log_info "Restaurando dados de jogadores e do mundo..."
        [ -d "$PROJECT_DIR/lib" ] && rm -rf "$PROJECT_DIR/lib"
        mv "$temp_data_dir"/lib "$PROJECT_DIR/"
        rm -rf "$temp_data_dir"
        log_success "Dados restaurados."
    fi

    (cd "$PROJECT_DIR" && git rev-parse HEAD > "../$VERSION_FILE")
}

apply_text_fixes() {
    log_info "Aplicando correções de texto no código fonte..."
    if [ ! -d "$PROJECT_DIR" ]; then log_error "Diretório do projeto '$PROJECT_DIR' não encontrado."; exit 1; fi
    cd "$PROJECT_DIR"
    
    local auction_file="src/act.auction.c"
    if ! grep -q "#include <stdio.h>" "$auction_file"; then
        sed -i '1i#include <stdio.h>' "$auction_file"
    fi
    
    mkdir -p bin; cd "$SCRIPT_DIR"
    log_success "Correções de texto aplicadas."
}

build_docker_image() {
    log_info "Construindo imagem Docker..."; cd "$PROJECT_DIR"
    
    log_info "  → Gerando Dockerfile..."
    cat > Dockerfile << 'EOF'
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y build-essential libz-dev && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY . .
RUN make -C src clean && make -C src all CFLAGS="-I.. -DNEED_STRLCPY_PROTO"
EXPOSE 4000
CMD ["./autorun"]
EOF
    
    log_info "  → Construindo a imagem (pode levar um tempo)..."
    docker build --platform linux/amd64 -t "$DOCKER_IMAGE:latest" .
    
    if [ $? -eq 0 ]; then log_success "Imagem Docker '$DOCKER_IMAGE:latest' construída com sucesso."; else log_error "Falha ao construir imagem Docker."; exit 1; fi
    cd "$SCRIPT_DIR"
}

run_container() {
    log_info "Iniciando container Docker..."
    if [ "$(docker ps -q -f name=$DOCKER_IMAGE)" ]; then log_warning "Container já está rodando!"; return; fi
    if [ "$(docker ps -aq -f name=$DOCKER_IMAGE)" ]; then log_info "Removendo container antigo parado..."; docker rm $DOCKER_IMAGE > /dev/null; fi

    log_info "🚀 Iniciando Vitalia Reborn..."
    docker run -d \
        --name "$DOCKER_IMAGE" \
        -p 4000:4000 \
        -v "$SCRIPT_DIR/$PROJECT_DIR/lib:/app/lib" \
        "$DOCKER_IMAGE:latest"

    if [ $? -eq 0 ]; then log_success "MUD iniciado com sucesso!"; show_summary; else log_error "Erro ao iniciar o MUD!"; exit 1; fi
}

stop_container() {
    log_info "🛑 Parando Vitalia Reborn..."
    if [ ! "$(docker ps -q -f name=$DOCKER_IMAGE)" ] && [ ! "$(docker ps -aq -f name=$DOCKER_IMAGE)" ]; then log_warning "Nenhum container encontrado."; return; fi
    [ "$(docker ps -q -f name=$DOCKER_IMAGE)" ] && docker stop $DOCKER_IMAGE > /dev/null
    [ "$(docker ps -aq -f name=$DOCKER_IMAGE)" ] && docker rm $DOCKER_IMAGE > /dev/null
    log_success "Container parado e removido com sucesso!"
}

export_area() {
    local vnum=$1; if [ -z "$vnum" ]; then log_error "Uso: ./reborn.sh --export-area [vnum]"; exit 1; fi
    log_info "Exportando área com VNUM $vnum..."
    
    local world_dir="$PROJECT_DIR/lib/world"
    if [ ! -d "$world_dir" ]; then log_error "Diretório '$world_dir' não encontrado."; exit 1; fi

    local temp_export_dir=".export_temp_$$"; mkdir -p "$temp_export_dir"
    local files_found=0
    local file_types=("wld" "mob" "obj" "shp" "zon" "trg" "qst")

    for type in "${file_types[@]}"; do
        local file_path="$world_dir/$type/$vnum.$type"
        if [ -f "$file_path" ]; then
            cp "$file_path" "$temp_export_dir/"
            files_found=$((files_found + 1))
        fi
    done

    if [ $files_found -eq 0 ]; then log_error "Nenhum arquivo de área encontrado para o VNUM $vnum."; rm -rf "$temp_export_dir"; exit 1; fi

    local zip_file="$SCRIPT_DIR/area_${vnum}.zip"
    log_info "Criando arquivo zip: area_${vnum}.zip"
    (cd "$temp_export_dir" && zip -q -r "$zip_file" ./*)
    
    rm -rf "$temp_export_dir"
    log_success "Área exportada com sucesso!"
}

import_area() {
    local zip_file=$1; if [ -z "$zip_file" ] || [ ! -f "$zip_file" ]; then log_error "Uso: ./reborn.sh --import-area [arquivo.zip]"; exit 1; fi
    
    local world_dir="$PROJECT_DIR/lib/world"
    if [ ! -d "$world_dir" ]; then log_error "Diretório '$world_dir' não encontrado."; exit 1; fi

    local temp_import_dir=".import_temp_$$"; mkdir -p "$temp_import_dir"
    unzip -q "$zip_file" -d "$temp_import_dir"

    log_info "Importando área do arquivo '$zip_file'..."
    for file in "$temp_import_dir"/*; do
        if [ -f "$file" ]; then
            local filename=$(basename "$file")
            local extension="${filename##*.}"
            
            if [ -d "$world_dir/$extension" ]; then
                log_info "  → Processando $filename..."
                mv "$file" "$world_dir/$extension/"
                
                local index_file="$world_dir/$extension/index"
                if [ ! -f "$index_file" ]; then
                    touch "$index_file"; echo "$" >> "$index_file"
                    log_warning "    Criado arquivo de índice não existente: $index_file"
                fi

                if grep -q "^$filename$" "$index_file"; then
                    log_info "    $filename já existe no índice."
                else
                    local entries=$(grep -v '^\$$' "$index_file")
                    entries="$entries"$'\n'"$filename"
                    local sorted_entries=$(echo "$entries" | sort -n | grep -v '^$')
                    echo "$sorted_entries" > "$index_file"; echo "$" >> "$index_file"
                    log_success "    $filename adicionado e índice ordenado."
                fi
            else
                log_warning "Diretório para a extensão '$extension' não encontrado. Pulando $filename."
            fi
        fi
    done

    rm -rf "$temp_import_dir"
    log_success "Importação concluída!"; log_warning "Reinicie o MUD para que as alterações tenham efeito."
}

reset_players() {
    if [ ! -d "$PROJECT_DIR/lib" ]; then log_error "Diretório '$PROJECT_DIR/lib' não encontrado."; exit 1; fi
    echo -e "${YELLOW}⚠️  ATENÇÃO: Este script irá DELETAR TODOS os jogadores!${NC}"
    read -p "Tem certeza que deseja continuar? (digite 'SIM' para confirmar): " confirm
    if [ "$confirm" != "SIM" ]; then log_error "Operação cancelada."; exit 1; fi

    log_info "🗑️  Limpando dados de jogadores..."; cd "$PROJECT_DIR"
    echo "~" > lib/plrfiles/index; log_success "✓ Index de jogadores limpo"
    find lib/plrobjs lib/plrvars lib/plrfiles -type f ! -name '00' -delete 2>/dev/null
    log_success "✓ Arquivos, objetos e variáveis de jogadores limpos"
    [ -d "lib/house" ] && find lib/house -type f -name "*.house" -delete 2>/dev/null; log_success "✓ Casas limpas"
    cd "$SCRIPT_DIR"; echo ""; log_success "✅ Reset completo! O próximo personagem criado será IMPLEMENTOR."
}

show_summary() {
    echo ""; echo -e "═══════════════════════════════════════════════════"; echo -e "  ${GREEN}O MUD está rodando em segundo plano!${NC}"; echo -e "═══════════════════════════════════════════════════"
    echo -e "  ${BLUE}Para conectar:${NC} telnet localhost 4000"; echo -e "  ${BLUE}Para ver os logs:${NC} docker logs -f $DOCKER_IMAGE"; echo -e "  ${BLUE}Para parar o MUD:${NC} ./reborn.sh --stop"; echo ""
}

show_help() {
    echo ""; echo -e "${YELLOW}reborn.sh - Ferramenta de Gestão para Vitalia Reborn MUD${NC}"; echo ""; echo "Uso: ./reborn.sh [comando] [argumento]"; echo ""
    echo -e "${BLUE}COMANDOS DE ATUALIZAÇÃO E COMPILAÇÃO:${NC}"; echo "  --update, -u             Verifica e instala atualizações do GitHub."; echo "  --force, -f              Força o download e a reconstrução completa."; echo "  --recompile, -r          Recompila o código local e reconstrói a imagem."
    echo ""; echo -e "${BLUE}COMANDOS DE CONTROLE DO MUD:${NC}"; echo "  --start                    Inicia o container do MUD."; echo "  --stop                     Para e remove o container do MUD."
    echo ""; echo -e "${BLUE}FERRAMENTAS DE IMPLEMENTADOR:${NC}"; echo "  --export-area [vnum]     Exporta todos os arquivos de uma área para um .zip."; echo "  --import-area [arquivo]  Importa uma área a partir de um arquivo .zip."; echo "  --reset-players          Apaga todos os dados de jogadores."
    echo ""; echo -e "${BLUE}AJUDA:${NC}"; echo "  --help, -h, (nenhum)       Exibe esta mensagem."; echo ""
}

main() {
    if [[ "$1" != "--help" && "$1" != "-h" && "$1" != "" ]]; then
        echo ""; echo "╔═══════════════════════════════════════════════════╗"; echo "║   Vitalia Reborn - Ferramenta de Gestão            ║"; echo "╚═══════════════════════════════════════════════════╝"; echo ""
    fi
    
    # A verificação de dependências agora é chamada por todos os comandos que precisam dela.
    case "$1" in
        --update|-u|--force|-f|--recompile|-r|--export-area|--import-area)
            check_dependencies
            ;;
    esac

    case "$1" in
        --update|-u)
            if check_for_updates; then
                stop_container; download_and_preserve; apply_text_fixes; build_docker_image; run_container
            fi
            ;;
        --force|-f)
            log_warning "Modo de reinstalação forçada ativado."; stop_container; download_and_preserve; apply_text_fixes; build_docker_image; run_container
            ;;
        --recompile|-r)
            log_warning "Modo de recompilação local ativado."; stop_container; apply_text_fixes; build_docker_image; run_container
            ;;
        --start) run_container ;;
        --stop) stop_container ;;
        --export-area) export_area "$2" ;;
        --import-area) import_area "$2" ;;
        --reset-players) reset_players ;;
        --help|-h|"") show_help ;;
        *)
            log_error "Argumento desconhecido: $1"; echo "Use './reborn.sh --help' para ver os comandos."; exit 1
            ;;
    esac
}

main "$@"
