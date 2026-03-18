#!/usr/bin/env bash

(
  set -eou pipefail
 
  # print this script's source
cat <<EOF
//thank you, https://filesig.search.org/
//  for your amazing table of file header signatures
//
//script to generate the list:
EOF

  # embed the script in the output
  declare -a filename="$(echo "${0}")"
  cat "${filename}" | sed 's|^|//  |g'

  printf '
pub const Filetype = struct {
  header:[]const u8,
  desc:[]const u8,
  type:[]const u8,
  ext:?[]const u8,
  trailer:?[]const u8,
  offset:usize,
};
'

  # create the table as an exported constant
  printf "\npub var the_list = [_]Filetype {\n"

  declare -a magic_json="$(curl \
      https://filesig.search.org \
      -H "Next-Action: 007ae5a86a81a6844c2dc2e3cc0b0cabfd998abda4" \
      -H "Content-Type: text/plain;charset=UTF-8" \
      -d '[]' \
      -S 2>/dev/null \
    | tail -n 1 \
    | sed 's/1://' \
    | jq '
      walk(
        if type == "string" and . == "(null)" or . == "(none)" or . == "$undefined" then
          null
        else
          .
        end
      ) | sort_by(
        ."Header (HEX)" | length
      ) | reverse
    ')"
  printf "%s" "${magic_json}" > magic.json

  # get the length of the json input
  declare -i len=$(printf "$magic_json" | jq '. | length')

  # iterate over the json
  for i in $(seq 0 $((len-1))); do

    # get the header
    declare header_R="$(printf "${magic_json}" | jq -r ".[${i}].\"Header (HEX)\"")"
    # skip short headers
    [[ ${#header_R} -lt 2 ]] && continue
    declare trailer_R="$(printf "${magic_json}" | jq -r ".[${i}].\"Trailer (Hex)\"")"

    # get the first hex digit
    declare -a header_first_dig=$(echo "${header_R}" | sed 's|'" "'.*||')
    # remove first digit if not 2 chars (not hex, there's a few of those)
    if [[ ${#header_first_dig} < 2 ]]; then
      header_R="$(echo "${header_R}" | sed 's|.* ||')";
    fi

    # replace the spaces with '\x' (for '\x00' formatted escape)
    declare -a header="$(echo "\x${header_R}" | sed 's| |\\x|g')"
    declare trailer="$(
      set +u 
      [[ "${trailer_R}" != "null" ]] && {
        echo "\"\x${trailer_R}\"" | sed 's| |\\x|g'
      } || echo "null"
      set -u 
    )"
    if [[ "${trailer}" == *"?"* ]]; then
      trailer="null"
    fi
    # get the file description (what it is) 
    declare -a desc="$(printf "${magic_json}" | jq ".[${i}].\"ASCII File Description\"")"
    # get the file class (eg: 'Picture')
    declare -a type="$(printf "${magic_json}" | jq ".[${i}].\"File Class\"")"
    declare -a offset="$(printf "${magic_json}" | jq ".[${i}].\"Header Offset\"")"
    declare -a selector=".[${i}].\"File Extension\""
    declare -a ext="$(printf "${magic_json}" | jq "if ${selector} == null then null else ${selector} | tostring end")"

    # print the object
    declare template='  .{
    .header = "%s",
    .desc = %s,
    .type = %s,
    .trailer = %s,
    .ext = %s,
    .offset = %d,
  },
'
    printf "${template}" "${header}" "${desc}" "${type}" "${trailer}" "${ext}" "${offset}"
  done
  # close the table
  printf "};\n"
)
