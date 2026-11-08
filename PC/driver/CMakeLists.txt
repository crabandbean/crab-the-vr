cmake_minimum_required(VERSION 3.20)
project(joyvr_driver CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Point this at a checkout of ValveSoftware/openvr:
#   git clone https://github.com/ValveSoftware/openvr ../third_party/openvr
set(OPENVR_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/openvr")

if(NOT EXISTS "${OPENVR_ROOT}/headers/openvr_driver.h")
	message(FATAL_ERROR
		"OpenVR headers not found at ${OPENVR_ROOT}. See PC/README.md for the clone command.")
endif()

add_library(joyvr_driver SHARED driver.cpp)

target_include_directories(joyvr_driver PRIVATE "${OPENVR_ROOT}/headers")

target_link_directories(joyvr_driver PRIVATE "${OPENVR_ROOT}/lib/win64")

target_link_libraries(joyvr_driver PRIVATE
	openvr_api
	d3d11
	dxgi
	mfplat
	mfuuid
	mfreadwrite
	ole32
	ws2_32)

target_compile_definitions(joyvr_driver PRIVATE
	UNICODE
	_UNICODE
	NOMINMAX)

# The driver DLL must sit next to its manifest:
#   SteamVR/drivers/joyvr/bin/win64/driver_joyvr.dll
#   SteamVR/drivers/joyvr/driver.vrdrivermanifest
set_target_properties(joyvr_driver PROPERTIES
	PREFIX ""
	OUTPUT_NAME "driver_joyvr")
