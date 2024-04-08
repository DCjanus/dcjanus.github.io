themes/DoIt/README.md: 
	git submodule update --init

preview: themes/DoIt/README.md
	hugo serve --disableFastRender --buildDrafts

serve: themes/DoIt/README.md
	hugo serve --disableFastRender

.PHONY: preview serve
