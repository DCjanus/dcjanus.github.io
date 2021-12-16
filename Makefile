themes/DoIt/README.md: 
	git submodule update --init

serve: themes/DoIt/README.md
	hugo serve --disableFastRender --buildDrafts