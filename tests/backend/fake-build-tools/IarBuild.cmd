@echo off
rem Fake IAR IarBuild.exe for CI/tests.
echo FAKE_BACKEND_OK IarBuild %*
exit /b 0