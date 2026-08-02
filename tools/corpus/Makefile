W3_SUITE = https://www.w3.org/Voice/2013/scxml-irp
SAXON = https://downloads.sourceforge.net/project/saxon/Saxon-HE/9.7/SaxonHE9-7-0-14J.zip
SCION_SUITE = https://github.com/jbeard4/scxml-test-framework.git

TXML = $(shell find test/scxml_w3 -type f -iname '*.txml')
W3_SCXML  = $(TXML:.txml=.scxml)
SCION_JSON = $(shell find test/scion -type f -iname '*.json')

test: generate
	@mix test

generate: test/scxml_w3/cases/.manifest saxon/saxon9he.jar $(W3_SCXML) test/scion/cases $(SCION_JSON)
	@$(MAKE) test/scxml_w3/cases/.cases test/scion/cases/.cases

test/scxml_w3/cases/.cases: $(W3_SCXML) test/scxml_w3/cases.exs
	@mix run test/scxml_w3/cases.exs $(W3_SCXML)
	@touch $@

test/scion/cases/.cases: $(SCION_JSON) test/scion/cases.exs
	@mix run test/scion/cases.exs $(SCION_JSON)
	@touch $@

%.scxml: %.txml test/scxml_w3/conf_elixir.xsl
	@java -jar saxon/saxon9he.jar --suppressXsltNamespaceCheck:on -s:$< -xsl:test/scxml_w3/conf_elixir.xsl -o:$@
	@echo $@

test/scxml_w3/cases/.manifest: test/scxml_w3/cases/manifest.xml test/scxml_w3/manifest.exs
	@mix run test/scxml_w3/manifest.exs test/scxml_w3/cases/manifest.xml $@ $(W3_SUITE)

test/scxml_w3/cases/manifest.xml:
	@mkdir -p test/scxml_w3/cases
	curl -L $(W3_SUITE)/manifest.xml -o $@

test/scion/cases: Makefile
	@rm -rf test/scion/cases
	@git clone $(SCION_SUITE) test/scion/.cases
	@rm -rf test/scion/.cases/test/w3c-ecma-in-review
	@rm -rf test/scion/.cases/test/w3c-ecma-modified
	@rm -rf test/scion/.cases/test/w3c-ecma
	@mv test/scion/.cases/test test/scion/cases

	@# Remove the root transition - not supported
	@sed -i.bak -e '25,28d' test/scion/cases/internal-transitions/test0.scxml

	@rm -rf test/scion/.cases

saxon/saxon9he.jar:
	@mkdir -p saxon
	@curl -L $(SAXON) -o saxon/saxon.zip
	@unzip -o saxon/saxon.zip -d saxon

clean:
	@rm -rf test/scxml_w3/cases
	@rm -rf test/scion/cases
	@rm -rf saxon

.PHONY: clean