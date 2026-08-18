cmake_minimum_required(VERSION 3.16)
project(firmware LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Debug)
endif()

add_executable(firmware
  src/main.c
  src/spi_flash.c
  src/pwm.c
  src/uart.c
)
target_include_directories(firmware PRIVATE include)

# Keep the output ELF name stable regardless of config.
set_target_properties(firmware PROPERTIES OUTPUT_NAME "firmware")

# Produce a map file next to the ELF (GCC/Clang ld).
if(CMAKE_C_COMPILER_ID MATCHES "GNU|Clang")
  target_link_options(firmware PRIVATE "-Wl,-Map=firmware.map")
endif()

# Copy final artifacts (elf / hex / map) to artifacts/build/ so the
# build.ps1 wrapper always finds them at the documented location.
set(FW_ARTIFACT_DIR "${CMAKE_SOURCE_DIR}/../artifacts/build")
add_custom_command(TARGET firmware POST_BUILD
  COMMAND ${CMAKE_COMMAND} -E make_directory ${FW_ARTIFACT_DIR}
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          $<TARGET_FILE:firmware> ${FW_ARTIFACT_DIR}/firmware.elf
  COMMAND ${CMAKE_COMMAND} -E copy_if_different
          ${CMAKE_CURRENT_BINARY_DIR}/firmware.map ${FW_ARTIFACT_DIR}/firmware.map
  COMMENT "Staging firmware ELF/map to artifacts/build/"
)

# Hex generation only for real MCU images (cross toolchains). The Windows
# host demo links a PE with 64-bit addresses which cannot map to Intel HEX;
# it stages a raw .bin placeholder instead so the artifact layout is exercised.
find_program(FW_OBJCOPY NAMES objcopy llvm-objcopy)
if(FW_OBJCOPY)
  if(WIN32)
    add_custom_command(TARGET firmware POST_BUILD
      COMMAND ${CMAKE_COMMAND} -E copy_if_different
              $<TARGET_FILE:firmware> ${FW_ARTIFACT_DIR}/firmware.bin
      COMMENT "Staging firmware.bin (host demo placeholder)")
  else()
    add_custom_command(TARGET firmware POST_BUILD
      COMMAND ${FW_OBJCOPY} -O ihex $<TARGET_FILE:firmware> ${FW_ARTIFACT_DIR}/firmware.hex
      COMMENT "Generating firmware.hex"
    )
  endif()
endif()