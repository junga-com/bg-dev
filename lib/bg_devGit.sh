
# usage: ipIsValid <ip>
# true if ip matches the pattern for a well formed dotted ip address
function isIPValid() { ipIsValid "$@"; }
function ipIsValid()
{
	local ipString=$1
	local saveIFS=$IFS; IFS='.'
	local ip=($ipString)
	IFS=$saveIFS

	[ ${#ip[@]} -ne 4 ] && return 1

	[[ $ipString =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ \
		&& ${ip[0]} -le 255 \
		&& ${ip[1]} -le 255 \
		&& ${ip[2]} -le 255 \
		&& ${ip[3]} -le 255 ]]
}


# usage: netResolve [-w timout] [-c tryCount] [-1] [-s <serverIP>] <hostOrIP>
# this function returns one or more dotted IP addresses associated with the hostOrIP input.
# It fails in a predictable and configurable ammount of time (timeout * tryCount)
# It allows overriding the configured DNS resolver servers
# Currently it returns only IPv4 IPs
# Algorithm:
#   * if hostOrIP is a dotted ip, it quickly returns it
#   * if hostOrIP is configued in hosts, it returns that without querying a server
#   * if dig is installed it uses dig with the timeout(default 1), tryCount(default 2), and server(default "") values
#   * if it still has not resolved, it uses host as a last resort. host works well in a healthy system but may
#     take 15 seconds to return failure in some cases which are difficult to predict and reproduce
# Input:
#   -w timeout  = how long to wait for each attempt. in seconds. default 1. only used if dig is invoked
#   -c tryCount = if timing out,how many times to try. default 2. only used if dig is invoked
#   -1          = pick one arbitrary, but consistent IP to return (there can be multiple IPs configured for each name)
#   -s serverIP = query this server if needed instead of the one chosen by the system. only used if dig is invoked
# Exit code:
#    0  = success. dooted ip(s) returned
#    1  = failure. empty string returned
function netResolve()
{
	local timeout="1" tryCount="2" pickOne server reverseFlag
	while [[ "$1" =~  ^- ]]; do case $1 in
		-w)  shift; timeout="$1" ;;
		-w*) timeout="${1#-w}" ;;
		-c)  shift; tryCount="$1" ;;
		-c*) tryCount="${1#-c}" ;;
		-s)  shift; server="@$1" ;;
		-s*) server="@${1#-s}" ;;
		-1)  pickOne="1" ;;
		-x)  reverseFlag="-x" ;;
	esac; shift; done

	local hostOrIP="$1"
	local -a ips

	if [ ! "$reverseFlag" ] && isIPValid "$ipOrHost"; then
		echo "$hostOrIP"
	elif grep "\s$hostOrIP\s*$" /etc/hosts &>/dev/null; then
		ips=( $(awk '/\s'"$hostOrIP"'\s*$/ {print $1}' /etc/hosts | sort -V) )
	elif [ ! "$reverseFlag" ] && which dig &>/dev/null; then
		ips=( $(dig $server +short +time="$timeout"  +tries="$tryCount" "$hostOrIP" | awk --posix '
			$1~"^([0-9]{1,3}\\.){3}[0-9]{1,3}$" {print $1}
			' | sort -V) ) || return
	elif [ "$reverseFlag" ] && which dig &>/dev/null; then
		ips=( $(dig $server +short +time="$timeout"  +tries="$tryCount" $reverseFlag "$hostOrIP" | awk --posix '
			{print $1}
			' | sort -V) ) || return
	elif [ "$reverseFlag" ]; then
		ips=( $(host -W"$timeout" -R"$tryCount" "$hostOrIP" ${server#@} | awk --posix '
			{print $NF}
			' | sort -V) ) || return
	else
		ips=( $(host -W"$timeout" -R"$tryCount" "$hostOrIP" ${server#@} | awk --posix '
			$NF~"^([0-9]{1,3}.){3}[0-9]{1,3}$" && $1!~":" {print $NF}
			' | sort -V) ) || return
	fi
	local ok=""
	for i in ${!ips[@]}; do
		if [ "$reverseFlag" ] || isIPValid "${ips[$i]}"; then
			echo ${ips[$i]}
			[ "$pickOne" ] && return
			ok="1"
		fi
	done
	[ "$ok" ] # set exit code
}


# usage: netPing [-q] [-w <timeout>] [-c <replyCount>] [-p <sendFloodCount>] [-i <sendInterval>] <targetHost>
#
# This determines a rough calculation of the quality of the connection to an <ip>
# It returns as soon as <replyCount> packets are received or <timeout> elapses.
# both the text output and exit code indicate the results. In general, The result is not
# a direct measure of packetloss because we don't know for sure how many packets will
# be sent out. Instead this is a measure of how many replies will make it back in timeout
# seconds. If sendInterval is set greater to the timeout, then this does become a measure
# of packet loss because we know that it sends exactly sendFloodCount packets at the start
# and no more during the timeout period.
#
# Controlling how ping requests are sent:
#   use -p sendFloodCount and -i sendInterval to determine how many and how oten ping requests are
#   sent. sendFloodCount are sent right away, all at once. Then after each sendInterval time
#   elapses, another single packet is sent. A non-root user is limited to 3 initial packaets
#   and another every 0.2 seconds. If more that that is specified the user my be prompted for a
#   sudo password. This command limits even root to at most 100 initial packets and 0.05 interval
#   which is 20 packets per second. If sendInterval is set to be greater than timeout, you
#   know that only the initial packets will be sent and the results can be interpreted as
#   a packet loss percentage.
# Controller when the commmand ends:
#   use -c replyCount and -w timeout to determine the conditions for the command to stop
#   The command returns when either replyCount replies have been recieved making the result
#   100, or timeout seconds have elapsed. If the timeout is reached, the result is the percentage
#   of replies received in that time. 0 means that no replies were received.
#
# Input:
#   <targetHost>     = the ip or hostname to be tested
#   -q               = do not write the 0 - 100 value -- exit code is the only output
#   -w timeout       = how long to wait before giving up on receiving any more packets
#                      timeout is also used for the dns lookup if target is not a dotted ip
#                      typically the call will still return in timeout seconds or less but
#                      if the condidtions are just right, the function could take 2*timeout
#   -c replyCount    = how many replies to wait for. Once this many have been received,
#                      it returns 100 and exit code success(0)
#   -p sendFloodCount= send out this many packets all at once. If this value is above 3,
#                      sudo is required and the user maybe prompted to enter their pw.
#                      100 is the max value this command allows to discourage flooding
#   -i sendInterval  = each time sendInterval time passes send out another packet. It seems
#                      that ping sends out only one packet each interval regardless of the
#                      sendFloodCount value.
#
# Output:
# it prints a number between 0 and 100 that represents the the quality of the connection
#        0 means there is no connectivity. This might mean that the dns or local net tests
#          failed meaning that it never even got to the test
#      100 means that the total
#
# The exit code is
#        0 == all packets <replyCount> received
#        1 == some packets received
#        2 == no packates received -- no connection at all
#        3 == no ping attempted. dns fail. ip is a host name and could not resolve it to a dotted IP
#        4 == no ping attempted. no network available -- ping'ing local host failed
#       10 == invalid targetHost (empty string)
#
# This is the algorithm it implements:
#   1) send out 'sendFloodCount' ping requests to the target ip all at once and then more packets every 0.2 seconds
#   2) after 'receiveCount' reply packets arrive return 0% immediately
#   3) if 'timout' is reached before 'receiveCount' replies, return (recieveCount - actualReceived) / recieveCount
#
# Note: if <replyCount> <= <sendFloodCount> a good quality connection will return very quickly
#       otherwise, after <sendFloodCount> get sent out, it waits in 0.2 second intervals to send more
# Note: The longest it will take is <timeout>. A down connection will always take that long
#
function netPing()
{
	local timeout="1" replyCount="3" sendFloodCount="3" quietFlag="" sendInterval="0.2" targetIP
	while [[ "$1" =~  ^- ]]; do case $1 in
		-w)  shift; timeout="$1" ;;
		-w*) timeout="${1#-w}" ;;
		-c)  shift; replyCount="$1" ;;
		-c*) replyCount="${1#-c}" ;;
		-p)  shift; sendFloodCount="$1" ;;
		-p*) sendFloodCount="${1#-p}" ;;
		-i)  shift; sendInterval="$1" ;;
		-i*) sendInterval="${1#-p}" ;;
		-q)  quietFlag="1" ;;
	esac; shift; done

	local targetHost=$1
	if [ ! "$targetHost" ]; then
		[ "$quietFlag" ] && return 10
		assertNotEmpty targetHost "netPing -q: targetHost should not be empty"
	fi
	local sudoCmd=""
	[ $sendFloodCount -gt   3 ] && sudoCmd="sudo "
	[ $sendFloodCount -gt 100 ] && assertError "getPLToIP: sendFloodCount should be less than 100"

	# first, test to see if we even have a network by looking up the local ip that will be used with the default route
	if ! ip route get 8.8.8.8 &>/dev/null; then
		[ ! "$quietFlag" ] && echo "0"
		return 4
	fi

	# do the dns lookup separately because in some cases a dns  lookup can take 15 seconds
	# note, if the variablr assignment is prefixed with 'local ', it eats the exit code
	local resolveTimeout="$timeout"; [ ${resolveTimeout:-0} -lt 2 ] && resolveTimeout=2
	if ! targetIP="$(netResolve -1 -w$resolveTimeout -c2 $targetHost)"; then
		[ ! "$quietFlag" ] && echo "0"
		return 3
	fi

	# this ping command line explained:
	#    -n   == dont waste time doing reverse dns lookups
	#    -l3  == send 3 at a time all at once, and exit after getting 3 replies
	#    -w1  == exit after 1 second regardless
	#   -i0.2 == after 0.2 seconds, send out more packets, it seems one at a time (not -l at a time)
	# $2=="bytes" matches the first reply line of the ping output and exits. When the
	# pipe (awk) exits, ping will be terminated too.
	# awk returns success (0) if it matches a packet replay and failure (1) if not
	# awk is used so that we can disconnect the the number sent and received.
	ping -n -c3 -i"$sendInterval" -l$sendFloodCount -w$timeout $targetIP | awk '
		$2=="bytes" {
			replyCount++;
			if (replyCount>='"$replyCount"')
				exit
		}
		END {
			if ("'$quietFlag'" == "")
				print (replyCount * 100) / "'$replyCount'"
			exit (replyCount>='"$replyCount"')? 0 : (replyCount) ? 1 : 2
		}'
	# the exit code will be that returned by awk (the last of the pipe)
}





# usage: gitPingRemote [-p] [-q] [-e] <gitURL>
# usage: gitPingRemote [-p] [-q] [-e] <remoteName>
# the exit code reflects if the remote repository is available at this moment and if not, why
# if <remoteName> is specified, the current working folder must be the local repo folder
# note: depending on the URL and user config on the server, the user could be prompted for their credentials
# Options:
#   -p : progressFlag. use progress calls to give feedback
#   -q : quiet. no output. normally it prints a one line description if the exit code is non-zero.
#   -e : this causes the case in which the remote is available but it is empty to return the
#        exitCode 6 instead of success
# Exit code:
#    0 == URL is valid and reachable (if -e is specified, 0 also means it has content)
#    1 == invalid url. parsing url did not produce a viable hostname
#    2 == remote host is down or unreachable via network
#    3 == could not resolve remote hostname
#    4 == network temporarily unavailable on this host, could not test
#    5 == remote host is up, but did not allow access to repo -- does not exist or permissions
#    6 == remote repo is available but its also empty (this is only reported if -e is specified)
function gitPingRemote()
{
	local verbose="1" emptyErrorCode="0" progressFlag
	while [ $# -gt 0 ]; do case $1 in
		-q)  verbose="" ;;
		-p)  progressFlag="-p" ;;
		-e)  emptyErrorCode="6" ;;
		*)  bgOptionsEndLoop "$@" && break; set -- "${bgOptionsExpandedOpts[@]}"; esac; shift;
	done

	# git ls-remote --get-url will translate the input URL based on mirror settings. pwd does not need to be a git repo
	local gitURL="$(git ls-remote --get-url "$1")"

	[ "$progressFlag" ] && progress -s "gitPing" "start"

	[ "$progressFlag" ] && progress -u "getting repo info"
	local protocol user password host port repoName parameters
	parseURL -p"git://" "$gitURL" protocol user password host port repoName parameters
	#bgtraceVars -1 gitURL protocol user password host port repoName parameters

	# check for invalid URL (might not handle all cases, but the git ls-remote cmd will catch what this does not)
	if [ "$protocol" != "file" ] && { [ ! "$host" ] || [[ ! "$host" =~ ^[0-9a-zA-Z.-]*$ ]]; }; then
		[ "$verbose" ] && echo "1 invalid URL. remote host could not be determined or is not valid. ($host)"
		[ "$progressFlag" ] && progress -e "gitPing" "invalid URL"
		return 1
	fi


	# if netPing fails with exit code 2, it could be that the remote does not accept pings but it will
	# accept the URL protocol so we investigate further
	[ "$progressFlag" ] && progress -u "netPing $host"
	netPing -q "$host"
	local pingResult="$?"

	# under some network circumstances, git ls-remote will take up to 30 seconds to fail. that is why we
	# did the netPing first. Still, because we don't know that remote host accepts pings we will still
	# get stuck here sometimes with a long delay
	# TODO: create netURLPing in bg_network.sh that pings using the protocol specified in the URL -- ie ssh,http,git, etc...
	local gitLSResult="notRun"
	if [ ${pingResult:-0} -le 1 ]; then
		[ "$progressFlag" ] && progress -u "git ls-remote (pingResult=$pingResult)"
		git ls-remote "$gitURL" noRe_fMatch 2>/dev/null
		gitLSResult=$?
	fi

	[ "$progressFlag" ] && progress -u "reporting"
	local exitCode=0
	case ${pingResult:-0}:${gitLSResult:-notRun} in
		# git ls-remote worked so netPing does not matter (maybe it failed b/c pings not allowed)
		*:0)
			if [ "$emptyErrorCode" != "0" ] && [ ! "$(git ls-remote -h "$gitURL")" ]; then
				[ "$verbose" ] && echo "$emptyErrorCode remote is available and is empty"
				exitCode=$emptyErrorCode
			fi
			;;
		2:*) [ "$verbose" ] && echo "git remote ($host) unreachable.";                                exitCode=2 ;;
		3:*) [ "$verbose" ] && echo "git remote ($host) unreachable. hostname could not resolve";     exitCode=3 ;;
		4:*) [ "$verbose" ] && echo "git remote ($host) unreachable. this host is not on a network";  exitCode=4 ;;

		# ping worked, so its a real git server problem
		0:*) [ "$verbose" ] && echo "git remote ($host) refused query";                               exitCode=5 ;;
		1:*) [ "$verbose" ] && echo "git remote ($host) refused query (network might be unreliable)"; exitCode=5 ;;

		*) assertError "this should never be reached" ;;
	esac
	[ "$progressFlag" ] && progress -e "gitPing" "done"
	return $exitCode
}





# usage: gitProj::loadAttributes <retAttribArrayVar> <gitFolder>
# This is the guts behind the gitStatus and gitInfo functions. It collects a number of high level attributes
# This should only initialize attributes that are quick to get and should not do any significant work.
# General Attributes:
#   displayName   : The simple name of the repo (no .git, no path)
#   gitFolder     : the path to the worktree
#   gitFolderOpt  : a string that contains git options that will cause git commands to operate on this project
#                   even if the PWD is not in the project
#   gitRepo       : the path to the hidden repo folder
#   remoteHost    : the actual host that will be used to pull changes from. This is useful to check reachability
#                   before git operations that might hang for a long time when the host is not available
#                   TODO: this should be split into branchHostPull and branchHostPush
#   changesStatus : an overall short description summarizing the state of the local repo
#                   [changes:<n>][behind:<m>][ahead:<o>][unique:<p>]    -- when the corresponding value is 0, the term is left out
#   syncState     : This is meant to guide the user to understand if the current branch is backed up
#                   dirtyFolder -- the worktree contains work that would be lost if not committed
#                   newCommits  -- the local repo contains commits that would be lost if not pushed somewhere
#                   syncd       -- all work in this branch is represented on the remote server
#                   TODO: we need to indicate if there are other branches that are not backed up to an upstream git server. if there is at least one other branch with changes append an '*'
#   canAmend      : True if the HEAD commit is not reachable by any other branch
#   dirtyIndicator: three characters that indicate 1) is the working tree dirty, 2) local commits vs remote commits,
#                   and 3) current content vs last release
#
# Branch Attributes:
#   branchName    : name of the current branch that the local worktree is on
#   branchType    : what type of branch is it
#                   local    -- only a local branch. there is no coresponding remote tracking branch (yet)
#                   tracking -- there is a local and remote branch and the local is configured to track the remote
#                   severed  -- there are both local and remote but the tracking config is missing
#                   detached -- no branch is set. a specific commit, or tag, was checked out and there and there is no local branch
#   branchRemote  : The remote (i.e. origin) that the current branch is tracking. "origin" is the default
#   branchMerge   : the value of the branch.$branchName.merge setting
#   branchTracking: the remote branch that the local branch is tracking. Typically its origin/$branchName
#   branchURL     : The logical (master) URL of the branchRemote. This might not be the URL used for operations
#                   but it is the identifier of the place where the branch is tracking
#   branchedFrom  : the branch that this branch was branched from. (recorded in the .bg{,local}/branches/ folder)
#                    if the branchType is 'local' this will be the branch that it was branched from.
#
# Repo State Attributes:
#   commitsBehind : how many commits are in the remote tracking branch that are not yet reflected in this local branch
#   commitsAhead  : how many commits are in the local branch that are not yet reflected in the remote branch
#                   note that for merges, this number counts all the commits merged. So performing a merge may bump
#                   this number more than one which I find unintuitive. If the merge is FF, this number could
#                   be non-zero even though there is no unique content in the the local branch
#   commitsAheadStr: oneline per commit description of the commitsAhead commits
#
# Worktree State Attributes:
#   changes       : text containing an output similar to 'git status -s'
#   changesCount  : a count of changes present in the working tree and index that would be in the next commit
#
# See Also:
#   gitInfo()
#   gitStatus()
function gitProj::loadAttributes()
{
	#varExists this || local -n this="$1"
	local gitFolder="${2:-${this[absPath]:-${this[path]}}}"

	[ ! -e "$gitFolder/.git" ] && assertError -v gitFolder "gitFolder is not a git working tree folder"

	local gitFolderOpt="-C $gitFolder";
	local gitRepo="$gitFolder/.git"; [ -f "$gitFolder/.git" ] && gitRepo="$(realpath --relative-to="$PWD" "$gitFolder/.git")"

	# save the identity information into the attribute array

	this[gitFolder]="$gitFolder"
	this[gitFolderOpt]="$gitFolderOpt"
	this[gitRepo]="$gitRepo"


	### get branch information

	this[branchName]="$(git $gitFolderOpt symbolic-ref --short HEAD 2>/dev/null)"
	this[branchName]="${this[branchName]:-HEAD}"

	# get the upstream branch info. If its not tracking, there is no real remote for this branch but in support of ondemand local
	# branches we fill in the branchRemote and branchTracking with the names it would have if we push the branch
	this[branchRemote]="$(git $gitFolderOpt config --get branch.${this[branchName]}.remote)"
	this[branchMerge]="$( git $gitFolderOpt config --get branch.${this[branchName]}.merge)"
	this[branchTracking]="${this[branchRemote]:-origin}/${this[branchName]}"
	this[branchURL]="$(git $gitFolderOpt config --get remote.${this[branchRemote]:-origin}.url)"
	this[branchURL]="${this[branchURL]:-${this[branchRemote]:-origin}}"

	# # the branchedFrom is either the tracking remote or the place that we branched from if there is no tracking branch
	# gitGetBranchedFrom -R this[branchedFrom] "$gitFolder" "${this[branchName]}"

	# determine the type of the branch
	if [ "${this[branchName]}" == "HEAD" ]; then
		this[branchType]="detached"
	elif [ "${this[branchMerge]}" ] && [ "$(git $gitFolderOpt cat-file -t "${this[branchTracking]}" 2>/dev/null)" ]; then
		this[branchType]="tracking"
	elif [ "$(git $gitFolderOpt cat-file -t "${this[branchTracking]}" 2>/dev/null)" ]; then
		this[branchType]="severed"
	else
		this[branchType]="local"
	fi


	### get the commitited repo state (commitsAhead and commitsBehind)

	# iterate the other branches that are not checked out to see if any are dirty
	$this.branches=new Map
	local -n branchesMap; GetOID ${this[branches]} branchesMap || assertError
	local branchIsHead branchName remoteBranch changes branchType
	while read -r branchIsHead branchName remoteBranch changes; do
		if [ "$branchIsHead" == "n" ]; then
			[ "$remoteBranch" == "--" ] && branchType="local" || branchType="tracking"
			if [ "$branchType" == "local" ]; then
				local aheadCount="$(git rev-list "$branchName" --not --exclude="$branchName" --remotes | wc -l)"
				[ ${aheadCount:-0} -gt 0 ] && changes="[ahead:$aheadCount]" || changes="[syncd]"
			else
				changes="${changes:-[syncd]}"
			fi
			branchesMap[$branchName]="$branchType ${changes}"
			[[ ! "$changes" =~ sync ]] && this[dirtyBranches]+="$branchName "
		fi
		#printfVars -1 branchIsHead branchName remoteBranch changes
	done < <(git for-each-ref --format='%(if)%(HEAD)%(then)y%(else)n%(end)  %(refname:strip=2) %(if)%(upstream)%(then)%(upstream:strip=2)%(else)--%(end)  %(upstream:track)' -- 'refs/heads')

	if [ "${this[branchType]}" == "tracking" ] || [ "${this[branchType]}" == "severed" ]; then
		this[commitsBehind]=$(   git $gitFolderOpt rev-list ${this[branchName]}..${this[branchTracking]} | wc -l)
		this[commitsAhead]=$(    git $gitFolderOpt rev-list ${this[branchTracking]}..${this[branchName]} | wc -l)
		this[commitsAheadStr]="$(git $gitFolderOpt log --oneline ${this[branchTracking]}..${this[branchName]} -- 2>/dev/null)"
		[ ${this[commitsAhead]:-0} -gt 0 ] && this[ffPush]="$(git $gitFolderOpt branch -r --contains "${this[branchName]}" | awk 'NR==1{exit;} END{if (NR>0) print "ffPush"}')"
		# TODO: after merging another branch into master that is all (or partial) FF because no changes were made to master since the other branch started,
		#        commitsAhead reports all those new commits which is missleading because we probably want to see that there are 0 or 1 new commits as a results
		#        of the merge.
		#        This is what commitsAheadUnique was getting at but that was also misleading. I think that commitsAhead should really be commitsUnsaved (new, not pushed to origin)
		#        and we should also indicated when a FF push is needed. I.E. after a FF merge to master, there are no new commits, but the state that needs to be pushed is just
		#        to update the origin/master to the local master.
	elif [ "${this[branchType]}" == "local" ]; then
		# local branches do not yet have a origin/<branchName> so report about commits that are not reachable from other refs

		# we are not tracking anything so we can not be behind anything
		this[commitsBehind]=0

		# this blocks uses 'git branch -r --contains $commitID' to walk back and count how many
		# commits are not reachable from any remote branch. These are commits that would be lost if
		# we lost the local repo
		# TODO: refactor this to use (aheadCount="$(git rev-list "$branchName" --not --exclude="$branchName" --remotes | wc -l)") or (git for-each-ref --contains|--no-merge|<something)>
		this[commitsAhead]=0
		local commitID="$(git $gitFolderOpt rev-parse "${this[branchName]}" 2>/dev/null)"
		while git $gitFolderOpt rev-parse --verify -q "$commitID" &>/dev/null && [ "$(git $gitFolderOpt branch -r --contains "$commitID" 2>/dev/null | awk 'NR==1{exit;} END{if (NR==0) print "dirty"}')" ]; do
			((this[commitsAhead]++))
			this[commitsAheadStr]+="${this[commitsAheadStr]:+$'\n'}$(git $gitFolderOpt log --oneline -1 ${commitID} 2>/dev/null)"
			commitID="$(git $gitFolderOpt rev-parse "${commitID}~1" 2>/dev/null)" || break
		done
	else
		# for detached branches (i.e. no branch) there is no concept of being ahead or behind
		this[commitsBehind]=0
		this[commitsAhead]=0
	fi

	# can the HEAD be reached by any other ref beside our branch? If this command returns only our this[branchName] (and no other lines), we could ammend it if we want to.
	this[canAmend]="$(git $gitFolderOpt branch -a --contains HEAD 2>/dev/null | awk 'NR==2{exit;} END{if (NR==1 && $2=="'"${this[branchName]}"'") print "yes"}')"


	### get the worktree change status

	# TODO: consider using 'git diff --name-only  HEAD' instead of 'git $gitFolderOpt status -uall --porcelain --ignore-submodules=dirty'. Its faster but does not including new files and does not distinguish between staged and unstaged changes but we don't really care about that anyway
	this[changes]="$(git $gitFolderOpt status -uall --porcelain --ignore-submodules=dirty | head -n200)"
	this[changesCount]="$(echo "${this[changes]}" | grep -v "^$" | wc -l )"


	### overall current branch info

	[[ "${this[changesCount]}" > 0 ]] \
		&& this[changesStatus]="changes:${this[changesCount]}"
	[[ ${this[commitsBehind]} > 0 ]]  \
		&& stringJoin -a -e -d"," -R this[changesStatus] "behind:${this[commitsBehind]}"
	[[ ${this[commitsAhead]}  > 0 ]] \
		&& stringJoin -a -e -d"," -R this[changesStatus] "ahead:${this[commitsAhead]}"

	# this case statement matches the most specific case first. When you see a * in one of the three fields
	# it means that its something other that the specific (0) value that preceeeds it
	case ${this[changesCount]}:${this[commitsAhead]}:${this[commitsBehind]}:${this[dirtyBranches]} in
		0:0:0:)    this[syncState]="syncd" ;;
		0:0:0:*)   this[syncState]="dirtyBranches" ;;
		0:0:*:)    this[syncState]="behind" ;;
		0:*:*:)    this[syncState]="newCommits"; [ "${this[ffPush]}" ] && this[syncState]="ffPush" ;;
		*:*:*:)    this[syncState]="dirtyFolder" ;;
	esac


	#git for-each-ref --format='%(refname) %(upstream)' -- 'refs/heads'

	# get the remote host and repoName. Note that the actual URL may not be the one in the config because of redirection config
	# that is why we run it through the 'ls-remote --get-url' command. We prefer the values in this order
	this[remoteHost]="$(git $gitFolderOpt ls-remote --get-url "${this[branchURL]}")"
	[ "${this[remoteHost]}" == "origin" ] && this[remoteHost]="" # if ls-remote did not translate 'origin' to a url, it does not exist
	local repoName
	parseURL -p"git://" "${this[remoteHost]}" "" "" "" this[remoteHost] "" repoName

	this[displayName]="$(getIniParam $gitFolder/.bg/bg-git.conf . name 2>/dev/null)"
	this[displayName]="${this[displayName]:-"${repoName:-${gitFolder}}"}"
	this[displayName]="${this[displayName]##*/}"
	this[displayName]="${this[displayName]%.git}"

	# get the last tag that looks like a version number if it exists
	# If a tag is found, it will be the latest release. If not it means that this proj has never been released
	# Note that the project might have a version stored that is already incremented for the next release.
	this[lastRelease]="$(git ${this[gitFolderOpt]} tag -l --sort="-version:refname" "v[0-9]*" | head -n1)"

	# releasePending is boolean that is true only if there has been a release and no changes in this folder since the last release
	# if (there has never been a published version)
	#    or (HEAD is past the last published version)
	#    or (the workTree is dirty)
	this[releasePending]=""
	if [ ! "${this[lastRelease]}" ] \
		|| [ "$(git ${this[gitFolderOpt]} rev-list "^${this[lastRelease]}" HEAD)" ] \
		|| [ ${this[changesCount]:-0} -gt 0 ]; then
		this[releasePending]="1"
	fi


	local dirtyIndicator
	# working tree vs checked out commit
	if [ ${this[changesCount]:-0} -gt 0 ]; then
		dirtyIndicator="-";
	else
		dirtyIndicator=" ";
	fi
	# local commits vs remote commits.
	if [ $((${this[commitsAhead]})) -gt 0 ] && [ $((${this[commitsBehind]})) -gt 0 ]; then
		dirtyIndicator+=":";
	elif [ $((${this[commitsAhead]})) -gt 0 ]; then
		dirtyIndicator+="-";
	elif [ $((${this[commitsBehind]})) -gt 0 ]; then
		dirtyIndicator+=".";
	else
		dirtyIndicator+=" ";
	fi
	# current content vs last release
	if [ "${this[releasePending]}" ]; then
		dirtyIndicator+="+"
	else
		dirtyIndicator+=" "
	fi
	this[dirtyIndicator]="$dirtyIndicator"
}
