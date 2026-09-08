@echo off
REM KirtasiyePOS - telefona kur (ortam degiskeninden bagimsiz calisir)
set "JAVA_HOME=C:\Program Files\Android\Android Studio\jbr"
set "ANDROID_HOME=%LOCALAPPDATA%\Android\Sdk"
set "ANDROID_SDK_ROOT=%LOCALAPPDATA%\Android\Sdk"
set "PATH=%JAVA_HOME%\bin;%ANDROID_HOME%\platform-tools;%ANDROID_HOME%\cmdline-tools\latest\bin;C:\src\flutter\bin;C:\Program Files\Git\bin;C:\Program Files\Git\cmd;%PATH%"
flutter run -d 21121119SG %*
