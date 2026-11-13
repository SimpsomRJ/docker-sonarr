#!/bin/bash
####################################################################
# strip.sh - script único para Radarr e Sonarr.                    #
#                                                                  #
# Mantém as faixas de áudio e as legendas de texto (SRT em MKV,    #
# mov_text em MP4) nos idiomas de $LANGS e remove o resto.         #
# Se nenhum áudio estiver nesses idiomas, mantém todos os áudios.  #
#                                                                  #
# Uso automático: Settings > Connect > Custom Script (On Import e  #
#                 On Upgrade), apontando para /scripts/strip.sh    #
# Uso manual:     strip.sh /caminho/arquivo.mkv                    #
#                                                                  #
# Créditos do código original:                                     #
#  https://github.com/theskyisthelimit/ubtuntumkvtoolnix           #
#  https://github.com/MarcelCosta79/RadarrM                        #
####################################################################

LANGS='^(eng|por|spa|und)$'
LOG="${STRIP_LOG:-/config/logs/striplog.txt}"

# Tudo vai para o log; se não der para gravar, segue na saída padrão.
if ! exec >> "$LOG" 2>&1; then
  echo "Aviso: não foi possível gravar em $LOG" >&2
fi

tmp=""
trap '[ -n "$tmp" ] && rm -f "$tmp"' EXIT

if [ -n "${1:-}" ]; then
  # Uso manual: o caminho vem como argumento.
  fpath="$1"
else
  # Chamado pelo Radarr/Sonarr: só age em importação/upgrade ("Download").
  # Test, Grab, Rename, exclusão etc. saem com sucesso sem fazer nada.
  event="${radarr_eventtype:-${sonarr_eventtype:-}}"
  [ "$event" = "Download" ] || exit 0
  fpath="${radarr_moviefile_path:-${sonarr_episodefile_path:-}}"
  [ -n "$fpath" ] || exit 0
fi

echo
date
echo "Arquivo: $fpath"

if [ ! -f "$fpath" ] || [ ! -r "$fpath" ]; then
  echo "Não foi possível ler o arquivo."
  exit 1
fi

dir=$(dirname "$fpath")

# Substitui o original somente se a ferramenta terminou bem e gerou saída.
# $1 = código de retorno, $2 = maior código aceito, $3 = nome da ferramenta
replace_original() {
  if [ "$1" -le "$2" ] && [ -s "$tmp" ]; then
    if mv -f "$tmp" "$fpath"; then
      tmp=""
      echo "Faixas indesejadas removidas."
      return 0
    fi
    echo "Falha ao substituir o original; arquivo preservado."
    return 1
  fi
  echo "$3 falhou (código $1); original preservado."
  return 1
}

strip_mkv() {
  local details audio subs keep_audio keep_subs total_audio total_subs rc
  local args=()
  local sel_audio='.type=="audio" and ((.properties.language // "und") | test($l))'
  local sel_subs='.type=="subtitles" and ((.codec // "") | test("srt"; "i")) and ((.properties.language // "und") | test($l))'

  details=$(mkvmerge -J "$fpath") || { echo "mkvmerge -J falhou."; return 1; }
  q() { jq -r --arg l "$LANGS" "$1" <<<"$details"; }

  audio=$(q "[.tracks[] | select($sel_audio) | .id | tostring] | join(\",\")") || return 1
  subs=$(q "[.tracks[] | select($sel_subs) | .id | tostring] | join(\",\")") || return 1
  keep_audio=$(q "[.tracks[] | select($sel_audio)] | length") || return 1
  keep_subs=$(q "[.tracks[] | select($sel_subs)] | length") || return 1
  total_audio=$(q '[.tracks[] | select(.type=="audio")] | length') || return 1
  total_subs=$(q '[.tracks[] | select(.type=="subtitles")] | length') || return 1

  echo "Áudio a manter: ${audio:-todos} ($keep_audio de $total_audio)"
  echo "Legendas a manter: ${subs:-nenhuma} ($keep_subs de $total_subs)"

  # Sem áudio nos idiomas desejados: mantém todos os áudios.
  if [ "$keep_audio" -gt 0 ] && [ "$keep_audio" -lt "$total_audio" ]; then
    args+=(-a "$audio")
  fi
  if [ "$keep_subs" -lt "$total_subs" ]; then
    if [ "$keep_subs" -gt 0 ]; then args+=(-s "$subs"); else args+=(-S); fi
  fi

  if [ ${#args[@]} -eq 0 ]; then
    echo "Nada a remover."
    return 0
  fi

  tmp="$dir/.strip.$$.mkv"
  mkvmerge -q "${args[@]}" -o "$tmp" "$fpath"
  rc=$?
  # mkvmerge: 0 = ok, 1 = avisos (saída válida), 2 = erro
  replace_original "$rc" 1 "mkvmerge"
}

strip_mp4() {
  local info audio subs keep_audio keep_subs total_audio total_subs rc i
  local maps=(-map "0:v?")
  local sel_audio='.codec_type=="audio" and ((.tags.language // "und") | test($l))'
  local sel_subs='.codec_type=="subtitle" and .codec_name=="mov_text" and ((.tags.language // "und") | test($l))'

  info=$(ffprobe -v error -show_streams -of json "$fpath") || { echo "ffprobe falhou."; return 1; }
  q() { jq -r --arg l "$LANGS" "$1" <<<"$info"; }

  audio=$(q "[.streams[] | select($sel_audio) | .index | tostring] | join(\" \")") || return 1
  subs=$(q "[.streams[] | select($sel_subs) | .index | tostring] | join(\" \")") || return 1
  keep_audio=$(q "[.streams[] | select($sel_audio)] | length") || return 1
  keep_subs=$(q "[.streams[] | select($sel_subs)] | length") || return 1
  total_audio=$(q '[.streams[] | select(.codec_type=="audio")] | length') || return 1
  total_subs=$(q '[.streams[] | select(.codec_type=="subtitle")] | length') || return 1

  echo "Áudio a manter: ${audio:-todos} ($keep_audio de $total_audio)"
  echo "Legendas a manter: ${subs:-nenhuma} ($keep_subs de $total_subs)"

  # Sem áudio nos idiomas desejados: mantém todos os áudios.
  if [ "$keep_audio" -eq 0 ]; then
    keep_audio=$total_audio
    audio=$(q '[.streams[] | select(.codec_type=="audio") | .index | tostring] | join(" ")') || return 1
  fi

  if [ "$keep_audio" -eq "$total_audio" ] && [ "$keep_subs" -eq "$total_subs" ]; then
    echo "Nada a remover."
    return 0
  fi

  for i in $audio $subs; do
    maps+=(-map "0:$i")
  done

  tmp="$dir/.strip.$$.mp4"
  ffmpeg -nostdin -y -v error -i "$fpath" "${maps[@]}" -c copy -movflags +faststart "$tmp"
  rc=$?
  replace_original "$rc" 0 "ffmpeg"
}

shopt -s nocasematch
case "$fpath" in
  *.mkv)       strip_mkv ;;
  *.mp4|*.m4v) strip_mp4 ;;
  *)           echo "Formato não suportado; arquivo ignorado." ;;
esac
exit $?
