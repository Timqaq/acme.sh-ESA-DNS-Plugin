#!/usr/bin/env sh
# shellcheck disable=SC2034
# Alibaba Cloud ESA DNS API plugin for acme.sh
#
# Required:
#   Ali_ESA_Key     - AccessKey ID
#   Ali_ESA_Secret  - AccessKey Secret
# Optional:
#   Ali_ESA_Region  - default: cn-hangzhou
#   Ali_ESA_SiteId  - skip auto-lookup if set

dns_ali_esa_add() {
  fulldomain="$1"
  txtvalue="$2"
  _info "Using Alibaba Cloud ESA DNS API"
  _ali_esa_load_config || return 1
  _debug "fulldomain=$fulldomain txtvalue=$txtvalue"
  _ali_esa_get_root "$fulldomain" || return 1
  _debug "_root=$_ali_esa_root _sub=$_ali_esa_sub"
  _ali_esa_get_site_id "$_ali_esa_root" || return 1
  _debug "SiteId=$_ali_esa_site_id"
  _ali_esa_create_record "$_ali_esa_site_id" "$fulldomain" "$txtvalue"
}

dns_ali_esa_rm() {
  fulldomain="$1"
  txtvalue="$2"
  _ali_esa_load_config || return 1
  _ali_esa_get_root "$fulldomain" || return 1
  _ali_esa_get_site_id "$_ali_esa_root" || return 1
  _ali_esa_delete_record "$_ali_esa_site_id" "$fulldomain" "$txtvalue"
}

# -------- config --------

_ali_esa_load_config() {
  Ali_ESA_Key="${Ali_ESA_Key:-$(_readaccountconf_mutable Ali_ESA_Key)}"
  Ali_ESA_Secret="${Ali_ESA_Secret:-$(_readaccountconf_mutable Ali_ESA_Secret)}"
  Ali_ESA_Region="${Ali_ESA_Region:-$(_readaccountconf_mutable Ali_ESA_Region)}"
  Ali_ESA_SiteId="${Ali_ESA_SiteId:-$(_readaccountconf_mutable Ali_ESA_SiteId)}"

  if [ -z "$Ali_ESA_Key" ] || [ -z "$Ali_ESA_Secret" ]; then
    _err "Ali_ESA_Key and Ali_ESA_Secret must be set"
    return 1
  fi
  [ -z "$Ali_ESA_Region" ] && Ali_ESA_Region="cn-hangzhou"
  _ali_esa_host="esa.${Ali_ESA_Region}.aliyuncs.com"

  _saveaccountconf_mutable Ali_ESA_Key    "$Ali_ESA_Key"
  _saveaccountconf_mutable Ali_ESA_Secret "$Ali_ESA_Secret"
  _saveaccountconf_mutable Ali_ESA_Region "$Ali_ESA_Region"
  [ -n "$Ali_ESA_SiteId" ] && _saveaccountconf_mutable Ali_ESA_SiteId "$Ali_ESA_SiteId"
  return 0
}

# -------- domain helpers --------

_ali_esa_get_root() {
  _full="$1"
  _ali_esa_root=""
  _ali_esa_sub=""
  _i=1
  while true; do
    _h=$(echo "$_full" | cut -d'.' -f"${_i}-")
    [ -z "$_h" ] && break
    case "$_h" in *.*) : ;; *) break ;; esac
    _debug "try site: $_h"
    if _ali_esa_find_site "$_h"; then
      _ali_esa_root="$_h"
      _pref="${_full%.$_h}"
      if [ "$_pref" = "$_full" ]; then
        _ali_esa_sub="@"
      else
        _ali_esa_sub="$_pref"
      fi
      return 0
    fi
    _i=$((_i + 1))
  done
  _err "Cannot find ESA site for $_full"
  return 1
}

_ali_esa_find_site() {
  _fs_name="$1"
  _ali_esa_site_id=""
  _resp=$(_ali_esa_call GET "ListSites" "PageNumber" "1" "PageSize" "20" "SiteName" "$_fs_name")
  _debug2 "ListSites($_fs_name): $_resp"
  echo "$_resp" | grep -q '"Code"' && return 1
  _sid=$(echo "$_resp" | _egrep_o '"SiteId" *: *[0-9]+' | head -1 | _egrep_o '[0-9]+$')
  _sname=$(echo "$_resp" | _egrep_o '"SiteName" *: *"[^"]*"' | head -1 | sed 's/.*"SiteName" *: *"\([^"]*\)".*/\1/')
  if [ -n "$_sid" ] && [ "$_sname" = "$_fs_name" ]; then
    _ali_esa_site_id="$_sid"
    return 0
  fi
  return 1
}

_ali_esa_get_site_id() {
  if [ -n "$Ali_ESA_SiteId" ]; then
    _ali_esa_site_id="$Ali_ESA_SiteId"
    return 0
  fi
  _ali_esa_find_site "$1"
}

# -------- record ops --------

_ali_esa_create_record() {
  _sid="$1"; _name="$2"; _val="$3"
  _data="{\"Value\":\"${_val}\"}"
  _resp=$(_ali_esa_call POST "CreateRecord" \
    "SiteId" "$_sid" "Type" "TXT" "RecordName" "$_name" "Data" "$_data" "Ttl" "120")
  _debug2 "CreateRecord: $_resp"
  if echo "$_resp" | grep -q '"RecordId"'; then
    _info "TXT record added successfully"
    return 0
  fi
  _err "CreateRecord failed: $_resp"
  return 1
}

_ali_esa_delete_record() {
  _sid="$1"; _name="$2"; _val="$3"
  _resp=$(_ali_esa_call GET "ListRecords" \
    "SiteId" "$_sid" "PageNumber" "1" "PageSize" "500" "Type" "TXT" "RecordName" "$_name")
  _debug2 "ListRecords: $_resp"
  _rid=$(echo "$_resp" | _egrep_o '"RecordId" *: *[0-9]+' | head -1 | _egrep_o '[0-9]+$')
  if [ -z "$_rid" ]; then
    _info "TXT record not found, skip"
    return 0
  fi
  _resp=$(_ali_esa_call POST "DeleteRecord" "SiteId" "$_sid" "RecordId" "$_rid")
  _debug2 "DeleteRecord: $_resp"
  _info "TXT record deleted (RecordId=$_rid)"
}

# -------- signing & HTTP --------
#
# _ali_esa_call METHOD Action [key value ...]
#   METHOD = GET | POST
#   For GET:  params go in URL query string
#   For POST: params go in request body (application/x-www-form-urlencoded)
#   Signature is computed identically, only verb differs in StringToSign

_ali_esa_call() {
  _method="$1"   # GET or POST
  _action="$2"
  shift 2

  _ts=$(date -u "+%Y-%m-%dT%H:%M:%SZ")
  _nonce="$(date -u +%s)$$${RANDOM}"

  # Collect all params into a temp file (one "k=v" per line, values are raw)
  _tmpf=$(mktemp /tmp/esa_XXXXXX)

  printf '%s\n' \
    "AccessKeyId=${Ali_ESA_Key}" \
    "Action=${_action}" \
    "Format=JSON" \
    "SignatureMethod=HMAC-SHA1" \
    "SignatureNonce=${_nonce}" \
    "SignatureVersion=1.0" \
    "Timestamp=${_ts}" \
    "Version=2024-09-10" \
    > "$_tmpf"

  while [ $# -ge 2 ]; do
    printf '%s\n' "${1}=${2}" >> "$_tmpf"
    shift 2
  done

  # URL-encode each k and v, collect "ek=ev" lines
  _enc_lines=""
  while IFS= read -r _ln; do
    [ -z "$_ln" ] && continue
    _ek=$(_ali_esa_urlencode "${_ln%%=*}")
    _ev=$(_ali_esa_urlencode "${_ln#*=}")
    _enc_lines="${_enc_lines}${_ek}=${_ev}
"
  done < "$_tmpf"
  rm -f "$_tmpf"

  # Sort and join with &
  _canonical=$(printf '%s' "$_enc_lines" | sort | tr '\n' '&' | sed 's/&$//')
  _debug2 "canonical: $_canonical"

  # StringToSign uses the actual HTTP method
  _sts="${_method}&%2F&$(_ali_esa_urlencode "$_canonical")"
  _debug2 "StringToSign: $_sts"

  # HMAC-SHA1, signing key = Secret + "&"
  _sig=$(printf '%s' "$_sts" \
    | openssl dgst -sha1 -hmac "${Ali_ESA_Secret}&" -binary 2>/dev/null \
    | openssl base64 2>/dev/null \
    | tr -d '\n')

  if [ -z "$_sig" ]; then
    _err "Signature generation failed (openssl not available?)"
    return 1
  fi
  _debug2 "Signature: $_sig"

  _sig_enc=$(_ali_esa_urlencode "$_sig")
  _base_url="https://${_ali_esa_host}/"

  if [ "$_method" = "POST" ]; then
    _body="${_canonical}&Signature=${_sig_enc}"
    _debug "POST $_base_url  body: $_body"
    export _H1="Content-Type: application/x-www-form-urlencoded"
    _post "$_body" "$_base_url"
    unset _H1
  else
    _url="${_base_url}?${_canonical}&Signature=${_sig_enc}"
    _debug "GET $_url"
    _get "$_url"
  fi
}

# RFC 3986 percent-encode (everything except unreserved: A-Z a-z 0-9 - _ . ~)
_ali_esa_urlencode() {
  printf '%s' "$1" | sed \
    -e 's/%/%25/g' \
    -e 's/ /%20/g' \
    -e 's/!/%21/g' \
    -e 's/"/%22/g' \
    -e "s/'/%27/g" \
    -e 's/(/%28/g' \
    -e 's/)/%29/g' \
    -e 's/\*/%2A/g' \
    -e 's/+/%2B/g' \
    -e 's/,/%2C/g' \
    -e 's|/|%2F|g' \
    -e 's/:/%3A/g' \
    -e 's/;/%3B/g' \
    -e 's/=/%3D/g' \
    -e 's/?/%3F/g' \
    -e 's/@/%40/g' \
    -e 's/\[/%5B/g' \
    -e 's/\\/%5C/g' \
    -e 's/\]/%5D/g' \
    -e 's/\^/%5E/g' \
    -e 's/{/%7B/g' \
    -e 's/|/%7C/g' \
    -e 's/}/%7D/g' \
    -e 's/#/%23/g' \
    -e 's/&/%26/g' \
    -e 's/`/%60/g'
}
