SUDO := `if command -v sudo >/dev/null 2>&1; then echo sudo; else echo doas; fi`

rebuild:
    rm -rf build
    bash build_ribbon.sh

install:
    rm -rf build
    bash build_ribbon.sh
    {{SUDO}} mkdir -p /usr/local/bin
    {{SUDO}} rm -f /usr/local/bin/ribbon
    {{SUDO}} cp build/ribbon /usr/local/bin/ribbon
    {{SUDO}} chmod 755 /usr/local/bin/ribbon
    mkdir -p ~/.config/ribbon
    rm -f ~/.config/ribbon/config.rib
    cp config.rib ~/.config/ribbon/config.rib

user-install:
    bash build_ribbon.sh
    mkdir -p ~/.local/bin
    cp build/ribbon ~/.local/bin/ribbon
    chmod 755 ~/.local/bin/ribbon
    mkdir -p ~/.config/ribbon
    rm -f ~/.config/ribbon/config.rib
    cp config.rib ~/.config/ribbon/config.rib

clean:
    rm -rf build
