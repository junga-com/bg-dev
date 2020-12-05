@include "bg_core.awk"


function vge(vLevel) {return verbosity >= vLevel}
function veq(vLevel) {return verbosity == vLevel}
BEGIN {
	if (ENVIRON["UT_DEBUG"]) bgtrace("fmt.awk starts BEGIN")
	arrayCreate(resultLists)
	arrayCreate2(resultLists,  "pass")
	arrayCreate2(resultLists,  "fail")
	arrayCreate2(resultLists,  "error")
	arrayCreate2(resultLists,  "uninit")

	arrayCreate(modLists)
	arrayCreate2(modLists,  "new")
	arrayCreate2(modLists,  "updated")
	arrayCreate2(modLists,  "unchanged")
	arrayCreate2(modLists,  "removed")

	totalCnt=0
}
veq(4) {print $0}
veq(2) && ($1!="pass" || $2!="unchanged") {print $0}
{
	resultLists[$1][length(resultLists[$1])]=$3
	modLists[$2][length(modLists[$2])]=$3
	totalCnt++
}
END {
	if (ENVIRON["UT_DEBUG"]) bgtrace("fmt.awk starts END")
	if (mode != "report")
		printf("%s testcases ran\n", totalCnt)
	else
		printf("%s testcases selected\n", totalCnt)

	if (totalCnt==0)
		exit

	if (mode != "report") {
		if (length(modLists["unchanged"])) printf("  %2s %s\n", length(modLists["unchanged"]), "unchanged")
		if (length(modLists["new"]))       printf("  %2s %s\n", length(modLists["new"]), "new")
		if (length(modLists["updated"]))   printf("  %2s %s\n", length(modLists["updated"]), "updated")
		if (length(modLists["removed"]))   printf("  %2s %s\n", length(modLists["removed"]), "removed")
	}

	printf("RESULTS\n")
	if (length(resultLists["pass"]))   printf("  %3s %s\n",  length(resultLists["pass"]),   "pass" )
	if (veq(3)) for (i in resultLists["pass"]) printf("      %s\n", resultLists["pass"][i])

	if (length(resultLists["fail"]))   printf("  %3s %s\n",  length(resultLists["fail"]),   "fail" )
	if (veq(3)) for (i in resultLists["fail"]) printf("      %s\n", resultLists["fail"][i])

	if (length(resultLists["error"]))  printf("  %3s %s\n",  length(resultLists["error"]),  "error" )
	if (veq(3)) for (i in resultLists["error"]) printf("      %s\n", resultLists["error"][i])

	if (length(resultLists["uninit"])) printf("  %3s %s\n",  length(resultLists["uninit"]), "un-initialized plato" )
	if (veq(3)) for (i in resultLists["uninit"]) printf("      %s\n", resultLists["uninit"][i])

	if (ENVIRON["UT_DEBUG"]) bgtrace("fmt.awk finshes END")
}
