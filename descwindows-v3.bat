@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "PROG=%~nx0"
set "OUTPUT_FILE=%CD%\descwindows-v3.txt"
set "SEPARADOR=************************************************************"
set "TMPDIR=%TEMP%"
if not defined TMPDIR set "TMPDIR=%CD%"

set "ROOTS_FILE=%TMPDIR%\descwindows-v3.%RANDOM%.roots"
set "REG_FILE=%TMPDIR%\descwindows-v3.%RANDOM%.reg"
set "HITS_FILE=%TMPDIR%\descwindows-v3.%RANDOM%.hits"
set "FOUND_FILE=%TMPDIR%\descwindows-v3.%RANDOM%.found"
set "FOUND_IDS_FILE=%TMPDIR%\descwindows-v3.%RANDOM%.ids"
set "CATALOG_FILE=%TMPDIR%\descwindows-v3.%RANDOM%.catalog"

set "SERVER_NAME=desconocido"
set "SERVER_IPS=desconocido"
set "SERVER_SO=desconocido"
set "SERVER_ARCH=desconocido"
set "SERVER_CPUS=desconocido"

break > "%OUTPUT_FILE%"
break > "%ROOTS_FILE%"
break > "%REG_FILE%"
break > "%HITS_FILE%"
break > "%FOUND_FILE%"
break > "%FOUND_IDS_FILE%"
break > "%CATALOG_FILE%"

call :build_catalog
call :collect_server_info
call :collect_registry_inventory
call :collect_candidate_roots
call :collect_file_hits
call :emit_server_block
call :process_hits
call :process_registry_only

type "%OUTPUT_FILE%"

set "EXITCODE=1"
if exist "%FOUND_FILE%" (
    for %%A in ("%FOUND_FILE%") do if %%~zA GTR 0 set "EXITCODE=0"
)

del "%ROOTS_FILE%" 2>nul
del "%REG_FILE%" 2>nul
del "%HITS_FILE%" 2>nul
del "%FOUND_FILE%" 2>nul
del "%FOUND_IDS_FILE%" 2>nul
del "%CATALOG_FILE%" 2>nul

exit /b %EXITCODE%

:build_catalog
>> "%CATALOG_FILE%" echo informix^|oninit.exe^|IBM Informix Enterprise Edition
>> "%CATALOG_FILE%" echo iidr^|dmts64.exe^|IBM InfoSphere Data Replication
>> "%CATALOG_FILE%" echo was^|wsadmin.bat^|IBM WebSphere Application Server
>> "%CATALOG_FILE%" echo ace^|mqsilist.exe^|IBM App Connect Enterprise / IBM Integration Bus
>> "%CATALOG_FILE%" echo mq^|dspmq.exe^|IBM MQ
>> "%CATALOG_FILE%" echo sterling^|control.bat^|IBM Sterling B2B / File Gateway
>> "%CATALOG_FILE%" echo sterling^|control.cmd^|IBM Sterling B2B / File Gateway
>> "%CATALOG_FILE%" echo secureproxy^|startSecureProxy.bat^|IBM Sterling Secure Proxy - Inbound
>> "%CATALOG_FILE%" echo secureproxy^|startSecureProxy.cmd^|IBM Sterling Secure Proxy - Inbound
>> "%CATALOG_FILE%" echo bpm^|BPMConfig.bat^|IBM Business Process Manager / IBM Business Automation Workflow
>> "%CATALOG_FILE%" echo bpm^|BPMConfig.cmd^|IBM Business Process Manager / IBM Business Automation Workflow
>> "%CATALOG_FILE%" echo odm^|DecisionCenter.ear^|IBM Operational Decision Manager
>> "%CATALOG_FILE%" echo odm^|teamserver.war^|IBM Operational Decision Manager
>> "%CATALOG_FILE%" echo csdk^|dbaccess.exe^|IBM Informix Client SDK
>> "%CATALOG_FILE%" echo c4gl^|c4gl.exe^|IBM Informix 4GL Compiler Development
>> "%CATALOG_FILE%" echo r4gl^|r4gl.exe^|IBM Informix 4GL Compiler Runtime Option
>> "%CATALOG_FILE%" echo fglgo^|fglgo.exe^|IBM Informix 4GL RDS Development
>> "%CATALOG_FILE%" echo db2^|db2level.exe^|IBM Db2
exit /b 0

:write_line
>> "%OUTPUT_FILE%" echo %~1
exit /b 0

:collect_server_info
for /f "delims=" %%A in ('hostname 2^>nul') do set "SERVER_NAME=%%A"

for /f "tokens=1,* delims==" %%A in ('wmic os get Caption^,Version^,OSArchitecture /value 2^>nul ^| find "="') do (
    if /i "%%A"=="Caption" set "OS_CAPTION=%%B"
    if /i "%%A"=="Version" set "OS_VERSION=%%B"
    if /i "%%A"=="OSArchitecture" set "SERVER_ARCH=%%B"
)
if defined OS_CAPTION (
    set "SERVER_SO=%OS_CAPTION%"
    if defined OS_VERSION set "SERVER_SO=%SERVER_SO% %OS_VERSION%"
)
if not defined SERVER_SO (
    for /f "delims=" %%A in ('ver') do set "SERVER_SO=%%A"
)

for /f "tokens=1,* delims==" %%A in ('wmic computersystem get NumberOfLogicalProcessors /value 2^>nul ^| find "="') do (
    if /i "%%A"=="NumberOfLogicalProcessors" set "SERVER_CPUS=%%B"
)
if not defined SERVER_CPUS if defined NUMBER_OF_PROCESSORS set "SERVER_CPUS=%NUMBER_OF_PROCESSORS%"

set "SERVER_IPS="
for /f "tokens=1,* delims==" %%A in ('wmic nicconfig where "IPEnabled=TRUE" get IPAddress /value 2^>nul ^| find "="') do (
    if /i "%%A"=="IPAddress" call :parse_ip_line "%%B"
)
if not defined SERVER_IPS (
    for /f "tokens=2 delims=:" %%A in ('ipconfig ^| findstr /i "IPv4"') do call :append_ip "%%A"
)
if not defined SERVER_IPS set "SERVER_IPS=desconocido"
if not defined SERVER_ARCH set "SERVER_ARCH=desconocido"
if not defined SERVER_CPUS set "SERVER_CPUS=desconocido"
if not defined SERVER_SO set "SERVER_SO=desconocido"
exit /b 0

:parse_ip_line
set "RAW_IPS=%~1"
set "RAW_IPS=%RAW_IPS:{=%"
set "RAW_IPS=%RAW_IPS:}=%"
set "RAW_IPS=%RAW_IPS:"=%"
set "RAW_IPS=%RAW_IPS:,= %"
for %%I in (%RAW_IPS%) do (
    call :append_ip "%%~I"
)
exit /b 0

:append_ip
echo %~1 | findstr /r "^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$" >nul || exit /b 0
if "%~1"=="127.0.0.1" exit /b 0
if "%~1"==" 127.0.0.1" exit /b 0
for /f "tokens=* delims= " %%A in ("%~1") do set "CLEAN_IP=%%A"
if not defined SERVER_IPS (
    set "SERVER_IPS=%CLEAN_IP%"
) else (
    echo ,%SERVER_IPS%, | findstr /c:",%CLEAN_IP%," >nul || set "SERVER_IPS=%SERVER_IPS%, %CLEAN_IP%"
)
set "CLEAN_IP="
exit /b 0

:collect_registry_inventory
call :collect_registry_hive "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall"
call :collect_registry_hive "HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
exit /b 0

:collect_registry_hive
for /f "delims=" %%K in ('reg query "%~1" 2^>nul ^| findstr /r /c:"HKEY_"') do (
    call :collect_registry_item "%%K"
)
exit /b 0

:collect_registry_item
set "REG_KEY=%~1"
set "DISPLAY_NAME="
set "DISPLAY_VERSION="
set "INSTALL_LOCATION="

for /f "tokens=1,2,*" %%A in ('reg query "%REG_KEY%" /v DisplayName 2^>nul ^| findstr /i "DisplayName"') do set "DISPLAY_NAME=%%C"
if not defined DISPLAY_NAME exit /b 0

for /f "tokens=1,2,*" %%A in ('reg query "%REG_KEY%" /v DisplayVersion 2^>nul ^| findstr /i "DisplayVersion"') do set "DISPLAY_VERSION=%%C"
for /f "tokens=1,2,*" %%A in ('reg query "%REG_KEY%" /v InstallLocation 2^>nul ^| findstr /i "InstallLocation"') do set "INSTALL_LOCATION=%%C"

>> "%REG_FILE%" echo %DISPLAY_NAME%^|%DISPLAY_VERSION%^|%INSTALL_LOCATION%
exit /b 0

:collect_candidate_roots
for %%D in ("%ProgramFiles%\IBM" "%ProgramFiles(x86)%\IBM" "C:\IBM" "C:\Informix") do (
    if exist "%%~D" >> "%ROOTS_FILE%" echo %%~fD
)

for /f "tokens=1,* delims==" %%A in ('wmic logicaldisk where "DriveType=3" get DeviceID /value 2^>nul ^| find "="') do (
    if /i "%%A"=="DeviceID" (
        if exist "%%B\IBM" >> "%ROOTS_FILE%" echo %%B\IBM
        if exist "%%B\Informix" >> "%ROOTS_FILE%" echo %%B\Informix
        if exist "%%B\Program Files\IBM" >> "%ROOTS_FILE%" echo %%B\Program Files\IBM
        if exist "%%B\Program Files (x86)\IBM" >> "%ROOTS_FILE%" echo %%B\Program Files ^(x86^)\IBM
    )
)

for /f "tokens=1,2,3 delims=|" %%A in (%REG_FILE%) do (
    if not "%%C"=="" if exist "%%C" >> "%ROOTS_FILE%" echo %%C
)
exit /b 0

:collect_file_hits
for /f "tokens=1,2,3 delims=|" %%A in (%CATALOG_FILE%) do (
    for /f "delims=" %%R in (%ROOTS_FILE%) do (
        if exist "%%R" (
            for /f "delims=" %%P in ('dir /s /b "%%R\%%B" 2^>nul') do (
                >> "%HITS_FILE%" echo %%A^|%%B^|%%P
            )
        )
    )
)
exit /b 0

:emit_server_block
call :write_line "%SEPARADOR%"
call :write_line "Información del servidor"
call :write_line "%SEPARADOR%"
call :write_line "Nombre del servidor: %SERVER_NAME%"
call :write_line "IP(s): %SERVER_IPS%"
call :write_line "Sistema operativo: %SERVER_SO%"
call :write_line "Arquitectura: %SERVER_ARCH%"
call :write_line "Cores/vCPUs del servidor: %SERVER_CPUS%"
call :write_line ""
exit /b 0

:process_hits
for /f "tokens=1,2,* delims=|" %%A in (%HITS_FILE%) do (
    call :emit_result_from_hit "%%A" "%%B" "%%C"
)
exit /b 0

:emit_result_from_hit
set "PRODUCT_ID=%~1"
set "SIGNATURE=%~2"
set "HIT_PATH=%~3"

findstr /x /c:"%PRODUCT_ID%|%HIT_PATH%" "%FOUND_FILE%" >nul 2>nul && exit /b 0

call :resolve_product_name "%PRODUCT_ID%" "%HIT_PATH%"
call :find_registry_match "%PRODUCT_ID%" "%HIT_PATH%"
call :probe_version "%PRODUCT_ID%" "%HIT_PATH%"

>> "%FOUND_FILE%" echo %PRODUCT_ID%^|%HIT_PATH%
>> "%FOUND_IDS_FILE%" echo %PRODUCT_ID%

call :write_line "%SEPARADOR%"
call :write_line "%PRODUCT_NAME% encontrado en este servidor"
call :write_line "%SEPARADOR%"
call :write_line "Ruta(s):"
call :write_line "%HIT_PATH%"
call :write_line ""
if defined VERSION_VALUE call :write_line "Versión: %VERSION_VALUE%"
if defined VERSION_STATUS call :write_line "Estado de versión: %VERSION_STATUS%"
if defined VERSION_METHOD call :write_line "Método de versión: %VERSION_METHOD%"
if defined VERSION_NOTE call :write_line "Nota de versión: %VERSION_NOTE%"
call :write_line "Fuente de detección: archivo"
call :write_line ""
exit /b 0

:process_registry_only
for /f "tokens=1,2,3 delims=|" %%A in (%REG_FILE%) do (
    call :emit_registry_only "%%A" "%%B" "%%C"
)
exit /b 0

:emit_registry_only
set "REG_NAME=%~1"
set "REG_VERSION=%~2"
set "REG_LOCATION=%~3"
set "REG_PRODUCT_ID="
set "REG_PRODUCT_NAME="

call :map_registry_to_product "%REG_NAME%"
if not defined REG_PRODUCT_ID exit /b 0

set "HIT_PATH=%REG_LOCATION%"
if not defined HIT_PATH set "HIT_PATH=desconocido"
findstr /x /c:"%REG_PRODUCT_ID%|%HIT_PATH%" "%FOUND_FILE%" >nul 2>nul && exit /b 0
call :resolve_product_name "%REG_PRODUCT_ID%" "%HIT_PATH%"

set "VERSION_VALUE=%REG_VERSION%"
if defined VERSION_VALUE (
    set "VERSION_STATUS=CONFIRMADA"
    set "VERSION_METHOD=registro de programas instalados"
    set "VERSION_NOTE="
) else (
    set "VERSION_VALUE="
    set "VERSION_STATUS=NO_DISPONIBLE"
    set "VERSION_METHOD=ninguno"
    set "VERSION_NOTE=No fue posible determinar la versión"
)

>> "%FOUND_FILE%" echo %REG_PRODUCT_ID%^|%HIT_PATH%
>> "%FOUND_IDS_FILE%" echo %REG_PRODUCT_ID%

call :write_line "%SEPARADOR%"
call :write_line "%PRODUCT_NAME% encontrado en este servidor"
call :write_line "%SEPARADOR%"
call :write_line "Ruta(s):"
call :write_line "%HIT_PATH%"
call :write_line ""
if defined VERSION_VALUE call :write_line "Versión: %VERSION_VALUE%"
if defined VERSION_STATUS call :write_line "Estado de versión: %VERSION_STATUS%"
if defined VERSION_METHOD call :write_line "Método de versión: %VERSION_METHOD%"
if defined VERSION_NOTE call :write_line "Nota de versión: %VERSION_NOTE%"
call :write_line "Fuente de detección: registro"
call :write_line ""
exit /b 0

:map_registry_to_product
set "REG_PRODUCT_ID="
set "REG_PRODUCT_NAME="
echo %~1 | findstr /i /c:"Business Automation Workflow" >nul && set "REG_PRODUCT_ID=bpm"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Business Process Manager" >nul && set "REG_PRODUCT_ID=bpm"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Operational Decision Manager" >nul && set "REG_PRODUCT_ID=odm"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"IBM MQ" >nul && set "REG_PRODUCT_ID=mq"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"App Connect Enterprise" >nul && set "REG_PRODUCT_ID=ace"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Integration Bus" >nul && set "REG_PRODUCT_ID=ace"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"WebSphere Application Server" >nul && set "REG_PRODUCT_ID=was"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Sterling Secure Proxy" >nul && set "REG_PRODUCT_ID=secureproxy"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Sterling File Gateway" >nul && set "REG_PRODUCT_ID=sterling"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Sterling B2B Integrator" >nul && set "REG_PRODUCT_ID=sterling"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"InfoSphere Data Replication" >nul && set "REG_PRODUCT_ID=iidr"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"IBM Data Replication" >nul && set "REG_PRODUCT_ID=iidr"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"IBM Db2" >nul && set "REG_PRODUCT_ID=db2"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"IBM DB2" >nul && set "REG_PRODUCT_ID=db2"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"IBM Informix Client SDK" >nul && set "REG_PRODUCT_ID=csdk"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Informix 4GL" >nul && echo %~1 | findstr /i /c:"Compiler" /c:"Development" >nul && set "REG_PRODUCT_ID=c4gl"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Informix 4GL" >nul && echo %~1 | findstr /i /c:"Runtime" >nul && set "REG_PRODUCT_ID=r4gl"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"Informix 4GL" >nul && echo %~1 | findstr /i /c:"RDS" >nul && set "REG_PRODUCT_ID=fglgo"
if not defined REG_PRODUCT_ID echo %~1 | findstr /i /c:"IBM Informix" >nul && set "REG_PRODUCT_ID=informix"
exit /b 0

:find_registry_match
set "REG_MATCH_NAME="
set "REG_MATCH_VERSION="
set "REG_MATCH_LOCATION="
for /f "tokens=1,2,3 delims=|" %%A in (%REG_FILE%) do (
    call :registry_name_matches "%~1" "%%A"
    if "!MATCH_OK!"=="1" (
        if "%%C"=="" (
            if not defined REG_MATCH_NAME (
                set "REG_MATCH_NAME=%%A"
                set "REG_MATCH_VERSION=%%B"
                set "REG_MATCH_LOCATION=%%C"
            )
        ) else (
            echo %~2 | findstr /i /c:"%%C" >nul && (
                set "REG_MATCH_NAME=%%A"
                set "REG_MATCH_VERSION=%%B"
                set "REG_MATCH_LOCATION=%%C"
            )
        )
    )
)
exit /b 0

:registry_name_matches
set "MATCH_OK=0"
set "TEST_ID=%~1"
set "TEST_NAME=%~2"
if /i "%TEST_ID%"=="informix" (
    echo %TEST_NAME% | findstr /i /c:"IBM Informix" >nul && echo %TEST_NAME% | findstr /i /v /c:"Client SDK" /c:"4GL" >nul && set "MATCH_OK=1"
)
if /i "%TEST_ID%"=="csdk" echo %TEST_NAME% | findstr /i /c:"IBM Informix Client SDK" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="db2" echo %TEST_NAME% | findstr /i /c:"IBM Db2" /c:"IBM DB2" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="iidr" echo %TEST_NAME% | findstr /i /c:"InfoSphere Data Replication" /c:"IBM Data Replication" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="mq" echo %TEST_NAME% | findstr /i /c:"IBM MQ" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="ace" echo %TEST_NAME% | findstr /i /c:"App Connect Enterprise" /c:"Integration Bus" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="was" echo %TEST_NAME% | findstr /i /c:"WebSphere Application Server" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="sterling" echo %TEST_NAME% | findstr /i /c:"Sterling File Gateway" /c:"Sterling B2B Integrator" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="secureproxy" echo %TEST_NAME% | findstr /i /c:"Sterling Secure Proxy" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="bpm" echo %TEST_NAME% | findstr /i /c:"Business Process Manager" /c:"Business Automation Workflow" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="odm" echo %TEST_NAME% | findstr /i /c:"Operational Decision Manager" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="c4gl" echo %TEST_NAME% | findstr /i /c:"Informix 4GL" /c:"Compiler" /c:"Development" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="r4gl" echo %TEST_NAME% | findstr /i /c:"Informix 4GL" /c:"Runtime" >nul && set "MATCH_OK=1"
if /i "%TEST_ID%"=="fglgo" echo %TEST_NAME% | findstr /i /c:"Informix 4GL" /c:"RDS" >nul && set "MATCH_OK=1"
exit /b 0

:resolve_product_name
set "PRODUCT_NAME="
if /i "%~1"=="was" (
    echo %~2 | findstr /i /c:"\dmgr\" /c:"NetworkDeployment" >nul && (
        set "PRODUCT_NAME=IBM WebSphere Application Server Network Deployment"
        exit /b 0
    )
    set "PRODUCT_NAME=IBM WebSphere Application Server"
    exit /b 0
)
if /i "%~1"=="sterling" (
    echo %~2 | findstr /i /c:"filegateway" /c:"file_gateway" >nul && (
        set "PRODUCT_NAME=IBM Sterling File Gateway"
        exit /b 0
    )
    echo %~2 | findstr /i /c:"b2bi" /c:"gentran" >nul && (
        set "PRODUCT_NAME=IBM Sterling B2B Integrator"
        exit /b 0
    )
    set "PRODUCT_NAME=IBM Sterling B2B / File Gateway"
    exit /b 0
)
if /i "%~1"=="bpm" (
    echo %~2 | findstr /i /c:"\BAW\" /c:"Business Automation Workflow" >nul && (
        set "PRODUCT_NAME=IBM Business Automation Workflow"
        exit /b 0
    )
    set "PRODUCT_NAME=IBM Business Process Manager"
    exit /b 0
)
for /f "tokens=1,2,* delims=|" %%A in (%CATALOG_FILE%) do (
    if /i "%%A"=="%~1" (
        set "PRODUCT_NAME=%%C"
        exit /b 0
    )
)
set "PRODUCT_NAME=Producto IBM no clasificado"
exit /b 0

:probe_version
set "VERSION_VALUE="
set "VERSION_STATUS="
set "VERSION_METHOD="
set "VERSION_NOTE="

if defined REG_MATCH_VERSION (
    set "VERSION_VALUE=%REG_MATCH_VERSION%"
    set "VERSION_STATUS=CONFIRMADA"
    set "VERSION_METHOD=registro de programas instalados"
    set "VERSION_NOTE="
)

if /i "%~1"=="informix" call :probe_informix "%~2"
if /i "%~1"=="csdk" if not defined VERSION_VALUE call :probe_file_version "%~2"
if /i "%~1"=="c4gl" if not defined VERSION_VALUE call :probe_file_version "%~2"
if /i "%~1"=="r4gl" if not defined VERSION_VALUE call :probe_file_version "%~2"
if /i "%~1"=="fglgo" if not defined VERSION_VALUE call :probe_file_version "%~2"
if /i "%~1"=="db2" call :probe_db2 "%~2"
if /i "%~1"=="iidr" call :probe_iidr "%~2"
if /i "%~1"=="mq" call :probe_mq "%~2"
if /i "%~1"=="ace" call :probe_ace "%~2"
if /i "%~1"=="was" call :probe_was "%~2"
if /i "%~1"=="secureproxy" if not defined VERSION_VALUE call :probe_file_version "%~2"
if /i "%~1"=="bpm" call :probe_bpm "%~2"

if /i "%~1"=="sterling" (
    if not defined VERSION_STATUS (
        set "VERSION_STATUS=INFERIDA"
        set "VERSION_METHOD=ruta de instalación"
        set "VERSION_NOTE=La clasificación se basó en la ruta detectada; no se confirmó una versión con un comando oficial"
    )
)

if not defined VERSION_VALUE call :infer_version_from_path "%~1" "%~2"

if not defined VERSION_STATUS (
    set "VERSION_STATUS=NO_DISPONIBLE"
    set "VERSION_METHOD=ninguno"
    set "VERSION_NOTE=No fue posible determinar la versión"
)
exit /b 0

:probe_informix
set "INFORMIX_ERROR="
for /f "delims=" %%L in ('"%~1" -V 2^>^&1') do (
    echo %%L | findstr /c:"IBM Informix Dynamic Server Version" >nul && (
        set "VERSION_VALUE=%%L"
        set "VERSION_VALUE=!VERSION_VALUE:*Version =!"
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=%~1 -V"
        set "VERSION_NOTE="
    )
    echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"not recognized" /c:"Unable to" >nul && set "INFORMIX_ERROR=%%L"
)
if not defined VERSION_VALUE if defined REG_MATCH_VERSION (
    set "VERSION_VALUE=%REG_MATCH_VERSION%"
    set "VERSION_STATUS=CONFIRMADA"
    set "VERSION_METHOD=registro de programas instalados"
    set "VERSION_NOTE="
)
if not defined VERSION_VALUE call :probe_file_version "%~1"
if not defined VERSION_VALUE if defined INFORMIX_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=%~1 -V"
    set "VERSION_NOTE=%INFORMIX_ERROR%"
)
set "INFORMIX_ERROR="
exit /b 0

:probe_db2
set "DB2_ERROR="
for /f "delims=" %%L in ('"%~1" 2^>^&1') do (
    echo %%L | findstr /c:"DB2 v" >nul && (
        for /f "tokens=2 delims=v" %%V in ("%%L") do (
            for /f "tokens=1 delims=, " %%W in ("%%V") do set "VERSION_VALUE=%%W"
        )
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=db2level"
        set "VERSION_NOTE="
    )
    echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"not recognized" /c:"SQL" >nul && set "DB2_ERROR=%%L"
)
if not defined VERSION_VALUE call :probe_file_version "%~1"
if not defined VERSION_VALUE if defined DB2_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=db2level"
    set "VERSION_NOTE=%DB2_ERROR%"
)
set "DB2_ERROR="
exit /b 0

:probe_iidr
set "TOOL=%~dp1dmshowversion.exe"
set "IIDR_ERROR="
if exist "%TOOL%" (
    for /f "delims=" %%L in ('"%TOOL%" 2^>^&1') do (
        echo %%L | findstr /b /c:"Version:" >nul && (
            for /f "tokens=1,* delims=:" %%A in ("%%L") do set "IIDR_VERSION=%%B"
        )
        echo %%L | findstr /b /c:"Build:" >nul && (
            for /f "tokens=1,* delims=:" %%A in ("%%L") do set "IIDR_BUILD=%%B"
        )
        echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"cannot be run" /c:"not recognized" >nul && set "IIDR_ERROR=%%L"
    )
    if defined IIDR_VERSION (
        set "VERSION_VALUE=%IIDR_VERSION: =%"
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=dmshowversion"
        if defined IIDR_BUILD set "VERSION_NOTE=Build:%IIDR_BUILD%"
    )
)
if not defined VERSION_VALUE call :probe_file_version "%~1"
if not defined VERSION_VALUE if defined IIDR_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=dmshowversion"
    set "VERSION_NOTE=%IIDR_ERROR%"
)
set "IIDR_VERSION="
set "IIDR_BUILD="
set "IIDR_ERROR="
exit /b 0

:probe_mq
set "TOOL=%~dp1dspmqver.exe"
set "MQ_ERROR="
if exist "%TOOL%" (
    for /f "delims=" %%L in ('"%TOOL%" -b 2^>^&1') do (
        echo %%L | findstr /b /c:"Version:" >nul && (
            for /f "tokens=1,* delims=:" %%A in ("%%L") do set "MQ_VERSION=%%B"
        )
        echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"not recognized" >nul && set "MQ_ERROR=%%L"
    )
    if defined MQ_VERSION (
        set "VERSION_VALUE=%MQ_VERSION: =%"
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=dspmqver -b"
        set "VERSION_NOTE="
    )
)
if not defined VERSION_VALUE call :probe_file_version "%~1"
if not defined VERSION_VALUE if defined MQ_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=dspmqver -b"
    set "VERSION_NOTE=%MQ_ERROR%"
)
set "MQ_VERSION="
set "MQ_ERROR="
exit /b 0

:probe_ace
set "TOOL=%~dp1mqsiversion.exe"
set "ACE_ERROR="
if exist "%TOOL%" (
    for /f "delims=" %%L in ('"%TOOL%" 2^>^&1') do (
        echo %%L | findstr /i /c:"Version" >nul && (
            for /f "tokens=1,* delims=:" %%A in ("%%L") do set "ACE_VERSION=%%B"
        )
        echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"not recognized" >nul && set "ACE_ERROR=%%L"
    )
    if defined ACE_VERSION (
        set "VERSION_VALUE=%ACE_VERSION: =%"
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=mqsiversion"
        set "VERSION_NOTE="
    )
)
if not defined VERSION_VALUE call :probe_file_version "%~1"
if not defined VERSION_VALUE if defined ACE_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=mqsiversion"
    set "VERSION_NOTE=%ACE_ERROR%"
)
set "ACE_VERSION="
set "ACE_ERROR="
exit /b 0

:probe_was
set "TOOL=%~dp1versionInfo.bat"
set "WAS_ERROR="
if exist "%TOOL%" (
    for /f "delims=" %%L in ('cmd /c ""%TOOL%" 2^>^&1"') do (
        echo %%L | findstr /i /c:"Product Version" >nul && (
            for /f "tokens=1,* delims=:" %%A in ("%%L") do set "WAS_VERSION=%%B"
        )
        echo %%L | findstr /i /c:"Network Deployment" >nul && set "WAS_NOTE=Se encontró evidencia de Network Deployment"
        echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"not recognized" /c:"failed" /c:"error" >nul && set "WAS_ERROR=%%L"
    )
    if defined WAS_VERSION (
        set "VERSION_VALUE=%WAS_VERSION: =%"
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=versionInfo.bat"
        if defined WAS_NOTE set "VERSION_NOTE=%WAS_NOTE%"
    )
)
if not defined VERSION_VALUE if defined WAS_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=versionInfo.bat"
    set "VERSION_NOTE=%WAS_ERROR%"
)
set "WAS_VERSION="
set "WAS_NOTE="
set "WAS_ERROR="
exit /b 0

:probe_bpm
set "TOOL=%~dp1BPMShowVersion.bat"
set "BPM_ERROR="
if exist "%TOOL%" (
    for /f "delims=" %%L in ('cmd /c ""%TOOL%" 2^>^&1"') do (
        echo %%L | findstr /i /c:"Version" >nul && (
            for /f "tokens=1,* delims=:" %%A in ("%%L") do set "BPM_VERSION=%%B"
        )
        echo %%L | findstr /i /c:"Access is denied" /c:"permission denied" /c:"not recognized" /c:"failed" /c:"error" >nul && set "BPM_ERROR=%%L"
    )
    if defined BPM_VERSION (
        set "VERSION_VALUE=%BPM_VERSION: =%"
        set "VERSION_STATUS=CONFIRMADA"
        set "VERSION_METHOD=BPMShowVersion.bat"
        set "VERSION_NOTE="
    )
)
if not defined VERSION_VALUE (
    set "TOOL=%~dp1versionInfo.bat"
    if exist "%TOOL%" (
        for /f "delims=" %%L in ('cmd /c ""%TOOL%" 2^>^&1"') do (
            echo %%L | findstr /i /c:"Product Version" >nul && (
                for /f "tokens=1,* delims=:" %%A in ("%%L") do set "BPM_VERSION=%%B"
            )
        )
        if defined BPM_VERSION (
            set "VERSION_VALUE=%BPM_VERSION: =%"
            set "VERSION_STATUS=CONFIRMADA"
            set "VERSION_METHOD=versionInfo.bat"
            set "VERSION_NOTE="
        )
    )
)
if not defined VERSION_VALUE if defined BPM_ERROR (
    set "VERSION_STATUS=BLOQUEADA"
    set "VERSION_METHOD=BPMShowVersion.bat / versionInfo.bat"
    set "VERSION_NOTE=%BPM_ERROR%"
)
set "BPM_VERSION="
set "BPM_ERROR="
exit /b 0

:probe_file_version
if defined VERSION_VALUE exit /b 0
echo %~1 | findstr /i /e /c:".exe" >nul || exit /b 0
set "WMIC_PATH=%~1"
set "WMIC_PATH=%WMIC_PATH:\=\\%"
for /f "tokens=1,* delims==" %%A in ('wmic datafile where "name='%WMIC_PATH%'" get Version /value 2^>nul ^| find "="') do (
    if /i "%%A"=="Version" set "FILE_VERSION=%%B"
)
if not defined FILE_VERSION if defined REG_MATCH_VERSION set "FILE_VERSION=%REG_MATCH_VERSION%"
if defined FILE_VERSION (
    set "VERSION_VALUE=%FILE_VERSION%"
    set "VERSION_STATUS=INFERIDA"
    if defined REG_MATCH_VERSION (
        set "VERSION_METHOD=registro de programas instalados"
        set "VERSION_NOTE=La versión proviene del registro; no se confirmó con comando oficial"
    ) else (
        set "VERSION_METHOD=versión del archivo ejecutable"
        set "VERSION_NOTE=La versión proviene del metadata del archivo"
    )
)
set "FILE_VERSION="
exit /b 0

:infer_version_from_path
if defined VERSION_VALUE exit /b 0
set "PATH_TO_PARSE=%~2"
if /i "%~1"=="db2" (
    for /f "tokens=2 delims=V\" %%A in ("%PATH_TO_PARSE%") do (
        for /f "tokens=1 delims=\" %%B in ("%%A") do set "VERSION_VALUE=%%B"
    )
)
if /i "%~1"=="informix" (
    echo %PATH_TO_PARSE% | findstr /i /c:"informix_" >nul && (
        for /f "tokens=2 delims=_" %%A in ("%PATH_TO_PARSE%") do (
            for /f "tokens=1 delims=\" %%B in ("%%A") do set "VERSION_VALUE=%%B"
        )
    )
)
if /i "%~1"=="csdk" (
    echo %PATH_TO_PARSE% | findstr /i /c:"informix_" >nul && (
        for /f "tokens=2 delims=_" %%A in ("%PATH_TO_PARSE%") do (
            for /f "tokens=1 delims=\" %%B in ("%%A") do set "VERSION_VALUE=%%B"
        )
    )
)
if /i "%~1"=="ace" (
    echo %PATH_TO_PARSE% | findstr /i /r /c:"ace[-_0-9]" /c:"iib[-_0-9]" >nul && set "VERSION_VALUE=detectada en ruta"
)
if defined VERSION_VALUE (
    set "VERSION_STATUS=INFERIDA"
    set "VERSION_METHOD=ruta de instalación"
    set "VERSION_NOTE=La versión se infirió desde la ruta detectada"
)
exit /b 0
