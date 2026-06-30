_minipro_zig()
{
    local cur prev words cword
    _init_completion || return

    local global_opts="--db --programmer -q --json --verbose --quiet --help -h --version -V"
    local legacy_opts="-Q --query_supported -k --presence_check -p -r -w -m -E -P -u -D -b -T -a -l -L -d"
    local commands="programmer db device chip logic"

    case "$prev" in
        --programmer|-q)
            COMPREPLY=( $(compgen -W "auto tl866a tl866ii t48 t56 t76" -- "$cur") )
            return
            ;;
        --format)
            COMPREPLY=( $(compgen -W "bin ihex srec config jedec" -- "$cur") )
            return
            ;;
        --package|-a)
            COMPREPLY=( $(compgen -W "8 16" -- "$cur") )
            return
            ;;
    esac

    case "${words[1]}" in
        programmer)
            COMPREPLY=( $(compgen -W "list detect info" -- "$cur") )
            ;;
        db)
            COMPREPLY=( $(compgen -W "import stats query --infoic --logicic --algorithms --out" -- "$cur") )
            ;;
        device)
            COMPREPLY=( $(compgen -W "list search info --limit" -- "$cur") )
            ;;
        chip)
            COMPREPLY=( $(compgen -W "read read-id autodetect blank verify erase write protect unprotect --device --in --out --format --memory --package --execute --confirm-destructive" -- "$cur") )
            ;;
        logic)
            COMPREPLY=( $(compgen -W "test --device --out --execute" -- "$cur") )
            ;;
        *)
            COMPREPLY=( $(compgen -W "$commands $global_opts $legacy_opts" -- "$cur") )
            ;;
    esac
}
complete -F _minipro_zig minipro-zig
