#!/usr/bin/env lua

local log = io.stderr

do

	--  a570a42e4b684bc7a8f9ae5ec60663c3: devuan-6 x86_64
	local baseImgNm = "a570a42e4b684bc7a8f9ae5ec60663c3.qcow2"
	local qemuCmd = "qemu-system-x86_64"
	local buildImgNm = "yaM1tcfgpUuIRwhq.qcow2"

	function getBaseImgNm() return assert(baseImgNm, "baseImgNm") end

	function getBuildImgNm() return assert(buildImgNm, "buildImgNm") end

	function getSshPrefx()
		return "ssh"
			.." -oConnectTimeout=1"
			.." -oUser=user"
			.." -oStrictHostKeyChecking=no"
			.." -oUserKnownHostsFile=/dev/null"
			.." -oPort=".. shEsc(getSshPort())
			.." 127.0.0.1"
	end

	function getSudoPrefx() return "sudo" end

	function getSshPort() return _ENV.arg[1] or 2222 end

	function getQemuCmd() return assert(qemuCmd, "qemuCmd") end

	function getBuildDepSet()
		return {
			["intltool"] = true,
			["libasound2"] = true,
			["libayatana-indicator3-dev"] = true,
			["libcurl4-gnutls-dev"] = true,
			["libfm-gtk3-dev"] = true,
			["libglib2.0-dev"] = true,
			["libgtk2.0-dev"] = true,
			["libiw-dev"] = true,
			["libkeybinder-3.0-dev"] = true,
			["libmenu-cache-dev"] = true,
			["libtool"] = true,
			["libwnck-3-dev"] = true,
			["libx11-dev"] = true,
			["libxml2-dev"] = true,
			["make"] = true,
			["pkg-config"] = true,
		}
	end

	function getRuntimeDepSet()
		return {
			["libfm-gtk-data"] = true,
			["libmenu-cache3"] = true,
			["lxmenu-data"] = true,
		}
	end

end


-- https://hiddenalpha.ch/slnk/id/1-ea62ea0b8635c39#f4a94246c53735a69
function shEsc( arg ) return "'".. tostring(arg):gsub("'", [['"'"']]) .."'" end


function createVmDisk()
	local ok, how, num = os.execute([=[set -e \
	  && cd ./tmp \
	  && if test -e ]=].. shEsc(getBuildImgNm()) ..[=[ ;then true \
	      && printf 'EEXISTS: %s\n' ']=].. shEsc(getBuildImgNm()) ..[=[' \
	    ;else true \
	      && qemu-img create -Fqcow2 -fqcow2 \
	          -b ]=].. shEsc(getBaseImgNm()) ..[=[ \
	          ]=].. shEsc(getBuildImgNm()) ..[=[ \
	    ;fi \
]=])
	if not ok then error(how .." ".. num) end
end


function startVm()
	local ok, how, num = os.execute([=[set -e \
	  && cd ./tmp \
	  && (]=].. shEsc(getQemuCmd()) ..[=[
	        -accel kvm -m size=2G -smp cores=$(($(nproc) / 2)) \
	        -hda ]=].. shEsc(getBuildImgNm()) ..[=[ \
	        -netdev user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:]=].. shEsc(getSshPort()) ..[=[-:22 \
	        -device e1000,netdev=n0 \
	        -display none \
	     ) > /dev/null & true \
	  && true \
]=])
	if not ok then error(how .." ".. num) end
	while true do
		local ok, how, num = os.execute(""
			.. getSshPrefx() .." -T true")
		if not ok and how == "exit" and num == 255 then
			log:write("Not yet reachable via ssh. Try later.\n")
			os.execute("sleep 7")
			goto probeSshReady
		end
		if not ok then error(how .." ".. num) end
		log:write("ssh looks ready\n")
		break
		::probeSshReady::
	end
end


function installDeps()
	local vmCmd = getSudoPrefx() .." apt install --no-install-recommends -y"
	for p, _ in pairs(getBuildDepSet()  ) do vmCmd = vmCmd .." ".. p end
	local ok, how, num = os.execute(getSshPrefx() .." -T ".. shEsc(vmCmd))
	if not ok then error(how .." ".. num) end
end


function trsfFilesInto()
	local ok, how, num = os.execute([=[set -e \
	  && tar c autogen.sh configure.ac data lxpanel.pc.in Makefile.am man plugins \
	       po src VERSIONING \
	     | ]=].. getSshPrefx() .." -T ".. shEsc("cd lxpanel && tar x") ..[=[ \
	  && true \
	]=])
	if not ok then error(how .." ".. num) end
end


function build()
	local cmd = [=[set -e \
	  && cd lxpanel \
	  && ./autogen.sh \
	  && ./configure --prefix="${PWD:?}"/build --enable-gtk3 --enable-debug --with-x \
	  && make \
	  && make install \
	]=]
	local ok, how, num = os.execute(getSshPrefx() .." -T ".. shEsc(cmd))
	if not ok then error(how .." ".. num) end
end


function trsfFilesOut()
	local cmd = [=[true \
	  && cd lxpanel \
	  && test -d build || mkdir build \
	  && test -d build/bin || mkdir build/bin \
	  && test -d build/lib || mkdir build/lib \
	  && cp -t build/bin/.  src/.libs/lxpanel src/lxpanelctl \
	  && cp -t build/lib/.  src/.libs/liblxpanel.so.0.0.0 src/.libs/liblxpanel.so.0 src/.libs/liblxpanel.so \
	  && (cd build && find -type f -exec sha256sum -b {} +) >> build/SHA256SUM \
	  && tar c build/bin/ build/lib/ build/SHA256SUM \
	]=]
	local ok, how, num = os.execute(
		getSshPrefx() .." -T ".. shEsc(cmd) .." | tar x")
	if not ok then error(how .." ".. num) end
end


function printUsageHint()
	log:write("\n"
		.."  As lxpanel depends on `liblxpanel.so`, but I already have installed\n"
		.."  stable on my system, I need to WURGH-around using `LD_LIBRARY_PATH`\n"
		.."  so I can test my debug-build:\n"
		.."  \n"
		.."  LD_LIBRARY_PATH=/path/to/dir:\"$LD_LIBRARY_PATH\" ./lxpanel\n"
		.."\n")
end


function main()
	createVmDisk()
	startVm()
	installDeps()
	trsfFilesInto()
	build()
	trsfFilesOut()
	printUsageHint()
end


main()
