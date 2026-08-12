<?xml version="1.0"?>
<!-- Copyright 1998-2003 W3C (MIT, ERCIM, Keio), All Rights Reserved. See http://www.w3.org/Consortium/Legal/. -->
<!-- Emits predicator expressions (ADR-0004), not ECMAScript.

     Boundness: predicator 5.0's `undefined` literal is a direct boundness
     test - `x === undefined` / `x !== undefined` never consults
     on_unbound. The comparison must stay strict (`===` / `!==`): `==` against
     `undefined` propagates the internal :undefined instead of returning a
     boolean, so a non-strict comparison is not a boundness test at all. The
     literal does not rescue a genuinely unbound ROOT - loading a root that was
     never bound still raises UndefinedVariableError under ADR-0014 item 5,
     because the load fails before the comparison runs. So a `Var<n>` cond only
     evaluates correctly once the datamodel seeds the declared `<data>` it
     names (st-af3.3); a property of an already-bound root (`_event.data`, a
     system variable) needs no such seeding.

     Templates with no predicator equivalent emit nothing useful on purpose;
     their tests are listed in exclusions.exs. Do not "fix" them by emitting
     ECMAScript - v1's corpus did that and the tests passed for the wrong
     reason. -->
<xsl:stylesheet
    xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
    xmlns:conf="http://www.w3.org/2005/scxml-conformance"
    version="2.0">

<!-- Copy everything that doesn't match other rules -->
<xsl:template match="/ | @* | node()">
  <xsl:copy>
    <xsl:apply-templates select="@* | node()"/>
  </xsl:copy>
</xsl:template>

<!-- Success criteria -->

<xsl:template match="//@conf:targetpass">
	<xsl:attribute name="target">pass</xsl:attribute>
</xsl:template>

<xsl:template match="conf:pass">
 <final xmlns="http://www.w3.org/2005/07/scxml" id="pass">
   <onentry>
     <log label="Outcome" expr="'pass'"/>
   </onentry>
 </final>
</xsl:template>

<!-- Failure criteria -->

<xsl:template match="//@conf:targetfail">
	<xsl:attribute name="target">fail</xsl:attribute>
</xsl:template>

<xsl:template match="conf:fail">
 <final xmlns="http://www.w3.org/2005/07/scxml" id="fail">
   <onentry>
    <log label="Outcome" expr="'fail'"/>
   </onentry>
</final>
</xsl:template>

<!-- datamodel -->
<xsl:template match="//@conf:datamodel">
	<xsl:attribute name="datamodel">predicator</xsl:attribute>
</xsl:template>


<!-- creates id for <data> element, etc. -->
<xsl:template match="//@conf:id">
	<xsl:attribute name="id">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>


<!-- creates name for <param>, etc. -->
<xsl:template match="//@conf:name">
	<xsl:attribute name="name">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>


<!-- creates location for <assign>, etc. -->
<xsl:template match="//@conf:location">
	<xsl:attribute name="location">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- names an invalid location for <assign>, etc. -->
<xsl:template match="//@conf:invalidLocation">
	<xsl:attribute name="location">foo.bar.baz </xsl:attribute>
</xsl:template>

<!-- uses system var as location for <assign>, etc. -->
<xsl:template match="//@conf:systemVarLocation">
	<xsl:attribute name="location"><xsl:value-of select="." /></xsl:attribute>
</xsl:template>




<!-- expr is evaluated -->
<xsl:template match="//@conf:expr">
	<xsl:attribute name="expr"><xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- targetexpr is the corresponding ID -->
<xsl:template match="//@conf:targetVar">
	<xsl:attribute name="targetexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- expr is quoted -->
<xsl:template match="//@conf:quoteExpr">
	<xsl:attribute name="expr">'<xsl:value-of select="." />'</xsl:attribute>
</xsl:template>

<!-- an expr that is the value of a variable -->
<xsl:template match="//@conf:varExpr">
	<xsl:attribute name="expr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- in EcmaScript, this is the same as varExpr -->
<xsl:template match="//@conf:varChildExpr">
	<xsl:attribute name="expr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- an expr that is the value of a system variable -->
<xsl:template match="//@conf:systemVarExpr">
	<xsl:attribute name="expr"><xsl:value-of select="." /></xsl:attribute>
</xsl:template>


<!-- an expr that is the value of a non-existent substructure of a variable -->
<xsl:template match="//@conf:varNonexistentStruct">
	<xsl:attribute name="expr">Var<xsl:value-of select="." />.bar</xsl:attribute>
</xsl:template>


<!-- this should return a value that cannot be assigned to a var.  -->
<xsl:template match="//@conf:illegalExpr">
	<xsl:attribute name="expr">return</xsl:attribute>
</xsl:template>

<!-- this should add 1 to the value of the specified variable -->
<xsl:template match="conf:incrementID">
	<assign xmlns="http://www.w3.org/2005/07/scxml">
	  <xsl:attribute name="location">Var<xsl:value-of select="@id"/></xsl:attribute>
	  <xsl:attribute name="expr">Var<xsl:value-of select="@id"/> + 1</xsl:attribute>
	  </assign>
	</xsl:template>

<!-- this  should concatenate the value of the id2 to id1 and assign the result to id1 -->
<xsl:template match="conf:concatVars">
	<assign xmlns="http://www.w3.org/2005/07/scxml">
	  <xsl:attribute name="location">Var<xsl:value-of select="@id1"/></xsl:attribute>
	  <xsl:attribute name="expr">Var<xsl:value-of select="@id1"/> + Var<xsl:value-of select="@id2"/></xsl:attribute>
	  </assign>
	</xsl:template>
	
<!-- assigns the sum of the values of two vars to thefirst var-->
<xsl:template match="//conf:sumVars"> 
	<assign xmlns="http://www.w3.org/2005/07/scxml">
<xsl:attribute name="location">Var<xsl:value-of select="@id1"/></xsl:attribute>
<xsl:attribute name="expr">Var<xsl:value-of select="@id1"/> + Var<xsl:value-of select="@id2"/></xsl:attribute>
	  </assign>
	</xsl:template>

<!-- this should return an illegal target for <send> causing a send error to be raised -->
<xsl:template match="//@conf:illegalTarget">
	<xsl:attribute name="target">baz</xsl:attribute>
</xsl:template>

<!-- this returns an legal, but unreachable, target for <send> causing a send error to be raised -->
<xsl:template match="//@conf:unreachableTarget">
	<xsl:attribute name="target">#_scxml_foo</xsl:attribute>
</xsl:template>

<!-- this produces illegal content for <send> causing the message to be rejected -->
<xsl:template match="//conf:illegalContent">
	<content xmlns="http://www.w3.org/2005/07/scxml"> xyz </content>
</xsl:template>

<!-- a content element whose value is the string 'foo' -->
<xsl:template match="//conf:contentFoo"> 
	<content xmlns="http://www.w3.org/2005/07/scxml">foo</content>
</xsl:template>

<xsl:template match="//conf:someInlineVal">123</xsl:template>

<!-- this returns something that is guaranteed not to be the ID of the current session -->
<xsl:template match="//@conf:invalidSessionID">
	<xsl:attribute name="expr">27</xsl:attribute>
</xsl:template>

<!-- this returns something that is guaranteed not to be a valid event I/O processor -->
<xsl:template match="//@conf:invalidSendType">
	<xsl:attribute name="type">27</xsl:attribute>
</xsl:template>

<!-- same value in an expr -->
<xsl:template match="//@conf:invalidSendTypeExpr">
	<xsl:attribute name="expr">27</xsl:attribute>
</xsl:template>

<!-- exprs that return the value of the event fields -->

<xsl:template match="//@conf:eventName">
	<xsl:attribute name="expr">_event.name</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:eventType">
	<xsl:attribute name="expr">_event.type</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:eventSendid">
	<xsl:attribute name="expr">_event.sendid</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:eventField">
	<xsl:attribute name="expr">_event.<xsl:value-of select="."/></xsl:attribute>
</xsl:template>

<!-- returns the raw message structure as a string.  Stubbed: BasicHTTP only. -->
<xsl:template match="//@conf:eventRaw">
</xsl:template>


<!-- returns the value of the specified item in  _event.data  -->
<xsl:template match="//@conf:eventDataFieldValue">
	<xsl:attribute name="expr">_event.data.<xsl:value-of select="."/></xsl:attribute>
</xsl:template>

<!-- returns the value of a KVP specified by <param> from  _event.data  -->
<xsl:template match="//@conf:eventDataParamValue">
	<xsl:attribute name="expr">_event.data.<xsl:value-of select="."/></xsl:attribute>
</xsl:template>
<!-- returns the value of a KVP specified by <param> from  _event.data  -->
<xsl:template match="//@conf:eventDataNamelistValue">
	<xsl:attribute name="expr">_event.data.Var<xsl:value-of select="."/></xsl:attribute>
</xsl:template>

<!-- returns the location of the scxml event i/o processor -->
<xsl:template match="//@conf:scxmlEventIOLocation">
	<xsl:attribute name="expr">_ioprocessors['http://www.w3.org/TR/scxml/#SCXMLEventProcessor'].location</xsl:attribute>
</xsl:template>

<!-- templates for the expr versions of the send attributes -->

<!-- eventexpr takes the value of the specified variable -->
<xsl:template match="//@conf:eventExpr">
	<xsl:attribute name="eventexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- targetexpr takes the value of the specified variable -->
<xsl:template match="//@conf:targetExpr">
	<xsl:attribute name="targetexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- typeexpr takes the value of the specified variable -->
<xsl:template match="//@conf:typeExpr">
	<xsl:attribute name="typeexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- delayexpr takes the value of the specified variable -->
<xsl:template match="//@conf:delayFromVar">
	<xsl:attribute name="delayexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- computes a delayexpr based on the value passed in.  this lets platforms determine how long to delay timeout
events which cause the test to fail.  The default value provided here is pretty long -->
<xsl:template match="//@conf:delay">
	<xsl:attribute name="delayexpr">'<xsl:value-of select="."/>s'</xsl:attribute>
</xsl:template>

<!--  the specified variable is used as idlocation -->
<xsl:template match="//@conf:idlocation">
	<xsl:attribute name="idlocation">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!--  the specified variable is used as sendidexpr -->
<xsl:template match="//@conf:sendIDExpr">
	<xsl:attribute name="sendidexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!--  the specified variable is used as srcexpr -->
<xsl:template match="//@conf:srcExpr">
	<xsl:attribute name="srcexpr">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!--  the specified variable is used as namelist -->
<xsl:template match="//@conf:namelist">
	<xsl:attribute name="namelist">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- this produces a reference to an invalid namelist, i.e. on that should cause an error -->
<xsl:template match="//@conf:invalidNamelist">
	<xsl:attribute name="namelist">&#34;foo</xsl:attribute>
</xsl:template>




<!-- transition conditions -->
<!-- the value is evaluated -->
<xsl:template match="//@conf:idVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)(.*)">
					<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
						<xsl:choose>
							<xsl:when test="$op='='">==</xsl:when>
							<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise>
					 </xsl:choose><xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>

		</xsl:analyze-string>
	</xsl:attribute>
</xsl:template>
<!-- compare two variables -->
<xsl:template match="//@conf:varIdVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)(.*)">
					<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
						<xsl:choose>
							<xsl:when test="$op='='">==</xsl:when>
							<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise>
					 </xsl:choose>Var<xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>

		</xsl:analyze-string>
	</xsl:attribute>
</xsl:template>


<!-- test that given var whose value was passed in via namelist has specific value. The value expr is evaluated -->
<xsl:template match="//@conf:namelistIdVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)(.*)">
					<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
						<xsl:choose>
							<xsl:when test="$op='='">==</xsl:when>
							<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise>
					 </xsl:choose><xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>

		</xsl:analyze-string>
	</xsl:attribute>
</xsl:template>

<!-- true if the two vars/ids have the same value -->
<xsl:template match="//@conf:VarEqVar">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)(\W+)([0-9]+)">
					<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/>===Var<xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>
		</xsl:analyze-string>
	</xsl:attribute>
</xsl:template>

<!-- true if the two vars/ids have the same value, which is a structure, not atomic -->
<xsl:template match="//@conf:VarEqVarStruct">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)(\W+)([0-9]+)">
					<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/>==Var<xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>
		</xsl:analyze-string>
	</xsl:attribute>
</xsl:template>

<!-- the value is quoted -->
<xsl:template match="//@conf:idQuoteVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)(.*)">
<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
<xsl:choose>
<xsl:when test="$op='='">==</xsl:when>
<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise></xsl:choose>'<xsl:value-of select="regex-group(3)"/>'</xsl:matching-substring>
</xsl:analyze-string>
</xsl:attribute>
</xsl:template>

<!-- test on the value of two vars -->
<xsl:template match="//@conf:compareIDVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)([0-9+])">
					<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
						<xsl:choose>
							<xsl:when test="$op='='">==</xsl:when>
							<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise>
					 </xsl:choose>Var<xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>
		</xsl:analyze-string>
	</xsl:attribute>
</xsl:template> 

<!-- test that the specified var has the value specified by <conf:someInlineVal> -->
<xsl:template match="//@conf:idSomeVal">
	<xsl:attribute name="cond">Var<xsl:value-of select="." /> == 123</xsl:attribute>
</xsl:template>

<!-- test that the event's name fieldhas the value specified -->
<xsl:template match="//@conf:eventNameVal">
		<xsl:attribute name="cond">_event.name == <xsl:text>'</xsl:text><xsl:value-of select="."/><xsl:text>'</xsl:text>
	</xsl:attribute>

</xsl:template>

<xsl:template match="//@conf:eventvarVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)(.*)">
					<xsl:matching-substring>_event.data['Var<xsl:value-of select="regex-group(1)"/><xsl:text>']</xsl:text><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
						<xsl:choose>
							<xsl:when test="$op='='">==</xsl:when>
							<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise>
					 </xsl:choose><xsl:value-of select="regex-group(3)"/>
					</xsl:matching-substring>

		</xsl:analyze-string>
	</xsl:attribute>

</xsl:template>



<!-- return true if variable matches value of system var (var number is first arg, system var name
is the second argument -->
<xsl:template match="//@conf:idSystemVarVal">
		<xsl:attribute name="cond">
		<xsl:analyze-string select="."
			regex="([0-9]+)([=&lt;&gt;]=?)(.*)">
<xsl:matching-substring>Var<xsl:value-of select="regex-group(1)"/><xsl:variable name="op"><xsl:value-of select="regex-group(2)"/></xsl:variable>
<xsl:choose>
<xsl:when test="$op='='">==</xsl:when>
<xsl:otherwise><xsl:value-of select="$op"/></xsl:otherwise></xsl:choose><xsl:value-of select="regex-group(3)"/></xsl:matching-substring>
</xsl:analyze-string>
</xsl:attribute>
</xsl:template>

<!-- return true if event.data field matches the specified value -->

<xsl:template match="//@conf:eventdataVal">
	<xsl:attribute name="cond">_event.data == <xsl:value-of select="."/></xsl:attribute>
</xsl:template>

<!-- test that _event.data is set to the value specified by <conf:someInlineVal> -->
<xsl:template match="//@conf:eventdataSomeVal">
	<xsl:attribute name="cond">_event.data == 123</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:emptyEventData">
	<xsl:attribute name="cond">_event.data === undefined</xsl:attribute>
</xsl:template>

<!-- return true if the _name system var has the specified quoted value -->
<xsl:template match="//@conf:nameVarVal">
	<xsl:attribute name="cond">_name == '<xsl:value-of select="."/>'</xsl:attribute>
</xsl:template>

<!-- return true if first var's value is a prefix of the second var's value.  Input has form "n m" where n and m are ints. -->
<xsl:template match="//@conf:varPrefix">
	<xsl:attribute name="cond">
	<xsl:analyze-string select="."
		regex="(\w+)\s+(\w+)">
<xsl:matching-substring>starts_with(Var<xsl:value-of select="regex-group(2)"/>, Var<xsl:value-of select="regex-group(1)"/>)</xsl:matching-substring>
	</xsl:analyze-string>
</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:inState">
	<xsl:attribute name="cond">In('<xsl:value-of select="."/>')</xsl:attribute>
</xsl:template>

<!-- returns a value that cannot be converted into a Boolean -->
<xsl:template match="//@conf:nonBoolean">
	<xsl:attribute name="cond">1</xsl:attribute>
</xsl:template>

<!-- true if id has a value -->
<xsl:template match="//@conf:isBound">
	<xsl:attribute name="cond">Var<xsl:value-of select="." /> !== undefined</xsl:attribute>
</xsl:template>

<!-- return true if specified var has been created but is not bound -->
<xsl:template match="//@conf:unboundVar">
	<xsl:attribute name="cond">Var<xsl:value-of select="." /> === undefined</xsl:attribute>
</xsl:template>

<!-- true if system var has a value -->
<xsl:template match="//@conf:systemVarIsBound">
	<xsl:attribute name="cond"><xsl:value-of select="." /> !== undefined</xsl:attribute>
</xsl:template>

<!-- true if id does not have a value -->
<xsl:template match="//@conf:noValue">
	<xsl:attribute name="cond">Var<xsl:value-of select="." /> === undefined</xsl:attribute>
</xsl:template>

<!-- always returns true -->
<xsl:template match="//@conf:true">
	<xsl:attribute name="cond">true</xsl:attribute>
</xsl:template>

<!-- always returns false -->
<xsl:template match="//@conf:false">
	<xsl:attribute name="cond">false</xsl:attribute>
</xsl:template>

<!-- returns true if all the required fields of _event are bound -->
  <xsl:template match="//@conf:eventFieldsAreBound">
    <xsl:attribute name="cond">_event.name !== undefined and _event.type !== undefined and _event.sendid !== undefined and _event.origin !== undefined and _event.origintype !== undefined and _event.invokeid !== undefined and _event.data !== undefined</xsl:attribute>
  </xsl:template>

<!-- returns true if  _event.data contains the specified item.
     Stubbed: predicator's `in` needs a list operand, not a map; unused by both trees. -->
<xsl:template match="//@conf:eventDataHasField">
</xsl:template>

<!-- returns true if specified field of _event has no value -->
<xsl:template match="//@conf:eventFieldHasNoValue">
	<xsl:attribute name="cond">_event.<xsl:value-of select="." /> === undefined</xsl:attribute>
</xsl:template>

<!-- true if the language of _event matches the processor's datamodel.  Unused by both trees. -->
<xsl:template match="//@conf:eventLanguageMatchesDatamodel">
	<xsl:attribute name="cond">_event.language == 'predicator'</xsl:attribute>
</xsl:template>

<!-- true if _event was delivered on the specified i/o processor -->
<xsl:template match="//@conf:originTypeEq">
	<xsl:attribute name="cond">_event.origintype == '<xsl:value-of select="."/>'</xsl:attribute>
</xsl:template>




<!-- scripting.  Stubbed: <script> is permanently out of scope (ADR-0004; test302-304). -->

<xsl:template match="conf:script">
</xsl:template>

<xsl:template match="//@conf:scriptGoodSrc">
</xsl:template>

<xsl:template match="//@conf:scriptBadSrc">
</xsl:template>

<!-- sends an event back to the sender of the current event -->
<xsl:template match="conf:sendToSender">
 <send xmlns="http://www.w3.org/2005/07/scxml">
 	<xsl:attribute name="event"><xsl:value-of select="@name" /></xsl:attribute>
   <xsl:attribute name="targetexpr">_event.origin</xsl:attribute>
   <xsl:attribute name="typeexpr">_event.origintype</xsl:attribute>
   </send>
</xsl:template>

<!-- foreach -->
<!-- this should produce an array containing 1 2 3 in that order -->
<xsl:template match="//conf:array123">[1,2,3]</xsl:template>

<!-- this uses the value of the indicated variable as the 'array' attribute -->
<xsl:template match="//@conf:arrayVar">
	<xsl:attribute name="array">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- in Python, this is the same as arrayVar -->
<xsl:template match="//@conf:arrayTextVar">
	<xsl:attribute name="array">Var<xsl:value-of select="."/></xsl:attribute>
</xsl:template>


<!-- this should produce expr that yields an array containing 1 2 3 in that order -->
<xsl:template match="//@conf:arrayExpr123">
	<xsl:attribute name="expr">[1,2,3]</xsl:attribute>
</xsl:template>

<!-- this should yield an expr that evaluates to something that is not a valid array  -->
<xsl:template match="//@conf:illegalArray">
		<xsl:attribute name="expr">7</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:item">
	<xsl:attribute name="item">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- this should return something that cannot be an variable name -->
<xsl:template match="//@conf:illegalItem">
	<xsl:attribute name="item">'continue'</xsl:attribute>
</xsl:template>

<xsl:template match="//@conf:index">
	<xsl:attribute name="index">Var<xsl:value-of select="." /></xsl:attribute>
</xsl:template>

<!-- this should add an extra item onto the end of the specified array, which
is of the same type as array123. -->
<xsl:template match="conf:extendArray">
	<assign xmlns="http://www.w3.org/2005/07/scxml">
	  <xsl:attribute name="location">Var<xsl:value-of select="@id"/></xsl:attribute>
	  <xsl:attribute name="expr">concat(Var<xsl:value-of select="@id"/>, [4])</xsl:attribute>
	  </assign>
	</xsl:template>

<!-- this should create a multidimensional array all of whose cells are set to the specified value.  Not
currently used for any tests  -->
<xsl:template match="//@conf:multiDimensionalArrayExpr">
		<xsl:attribute name="expr">[[<xsl:value-of select="."/>,<xsl:value-of select="."/>],[<xsl:value-of select="."/>,<xsl:value-of select="."/>]]</xsl:attribute>
</xsl:template>


<!-- this  should create a <foreach> statement that increments the values of the specified array.  Not
currently used for any tests.
Stubbed: relies on <script>, permanently out of scope (ADR-0004). -->
<xsl:template match="conf:incrementArray">
</xsl:template>

<!-- this should return true iff each cell in the specified multidimensional array has the specified value. Not
currently used for any tests.
Stubbed: multidimensional array comparison has no predicator equivalent. -->
<xsl:template match="//@conf:arrayVal">
</xsl:template>

<!-- SITE SPECIFIC INFORMATION FOR BASIC HTTP EVENT I/O PROCESSOR

BasicHTTP Event I/O Processor support is out of scope (exclusions.exs,
:needs_basichttp). Every template below is stubbed rather than emitting the
regex-based ECMAScript forms the upstream stylesheet used. -->

<xsl:template match="//@conf:testOnServer">
</xsl:template>

<xsl:template match="conf:setUpHTTPTest">
</xsl:template>

<xsl:template match="//@conf:basicHTTPAccessURI">
</xsl:template>

<xsl:template match="//@conf:basicHTTPAccessURITarget">
</xsl:template>

<xsl:template match="//@conf:methodIsPost">
</xsl:template>

<xsl:template match="//@conf:multipleNamelist">
</xsl:template>

<xsl:template match="//@conf:eventIdParamHasValue">
</xsl:template>

<xsl:template match="//@conf:eventNamedParamHasValue">
</xsl:template>

<xsl:template match="//@conf:messageBodyEquals">
</xsl:template>

<xsl:template match="//@conf:getNamedParamVal">
</xsl:template>

<xsl:template match="//@conf:getIDParamVal">
</xsl:template>

<xsl:template match="//@conf:getNthParamName">
</xsl:template>

<xsl:template match="//@conf:getNthParamVal">
</xsl:template>

<xsl:template match="//@conf:scxmlEventExpr">
</xsl:template>

<xsl:template match="conf:msgContent">
</xsl:template>

<xsl:template match="//@conf:msgIsBody">
</xsl:template>
</xsl:stylesheet>