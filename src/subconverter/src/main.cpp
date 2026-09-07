#include <iostream>
#include <string>
#include <unistd.h>
#include <csignal>
#include <chrono>
#include <thread>

#include <sys/types.h>
#include <dirent.h>

#include "config/ruleset.h"
#include "handler/interfaces.h"
#include "handler/webget.h"
#include "handler/settings.h"
#include "script/cron.h"
#include "server/socket.h"
#include "server/webserver.h"
#include "utils/defer.h"
#include "utils/file_extra.h"
#include "utils/logger.h"
#include "utils/network.h"
#include "utils/rapidjson_extra.h"
#include "utils/system.h"
#include "utils/urlencode.h"
#include "version.h"

//#include "vfs.h"

WebServer webServer;

#ifndef _WIN32
void SetConsoleTitle(const std::string &title)
{
    system(std::string("echo \"\\033]0;" + title + R"(\007\c")").data());
}
#endif // _WIN32

void setcd(std::string &file)
{
    char szTemp[1024] = {}, filename[256] = {};
    std::string path;
#ifdef _WIN32
    char *pname = NULL;
    DWORD retVal = GetFullPathName(file.data(), 1023, szTemp, &pname);
    if(!retVal)
        return;
    strcpy(filename, pname);
    strrchr(szTemp, '\\')[1] = '\0';
#else
    char *ret = realpath(file.data(), szTemp);
    if(ret == nullptr)
        return;
    ret = strcpy(filename, strrchr(szTemp, '/') + 1);
    if(ret == nullptr)
        return;
    strrchr(szTemp, '/')[1] = '\0';
#endif // _WIN32
    file.assign(filename);
    path.assign(szTemp);
    chdir(path.data());
}

#ifndef _WIN32
static pid_t watched_parent_pid = 0;

/// 跟随父进程退出。父进程被 kill -9 / 崩溃 / 被调试器停止时,子进程会被 launchd 收养继续
/// 活着;而 httplib 无条件开了 SO_REUSEPORT(include/httplib.h:1783),遗留进程和新进程能
/// 同时 bind 同一个端口,请求随机落到哪个都有可能——落到旧进程就会拿到旧结果。
///
/// 要监视的 pid 由调用方显式传入,不用 getppid() 自己推断:进程刚起来那会儿父进程可能
/// 已经先退了(实测 `sh -c 'cmd &'` 就是如此),那时候取到的基准值本身就是 1,再怎么比都
/// 等不到变化。显式传值则连「父进程已经没了」这种情况都能在第一轮循环就判出来。
/// 仅在显式传 --exit-with-parent 时启用:Docker 里进程常常自己就是 PID 1,不能一概而论。
static void startParentWatchdog(pid_t parent)
{
    std::thread([parent]()
    {
        // kill(pid, 0) 只探测存活、不投递信号;getppid() 变了同样说明父进程没了
        while(kill(parent, 0) == 0 && getppid() == parent)
            std::this_thread::sleep_for(std::chrono::seconds(2));
        writeLog(0, "Parent process " + std::to_string(parent) + " exited. Shutting down.", LOG_LEVEL_FATAL);
        webServer.stop_web_server();
        // 兜底:父进程已经没了,没人会来收拾残局。优雅停不下来(比如监听还没起来)就硬退,
        // 绝不能留一个占着端口的孤儿进程。
        std::this_thread::sleep_for(std::chrono::seconds(3));
        _exit(0);
    }).detach();
}
#endif // _WIN32

void chkArg(int argc, char *argv[])
{
    for(int i = 1; i < argc; i++)
    {
#ifndef _WIN32
        if(strcmp(argv[i], "--exit-with-parent") == 0)
        {
            // 可带 pid;省略时退回 getppid(),但那样就有上面说的竞态,调用方应显式传
            watched_parent_pid = (i < argc - 1) ? static_cast<pid_t>(to_int(argv[++i], 0)) : getppid();
            if(watched_parent_pid <= 0)
                watched_parent_pid = getppid();
            continue;
        }
#endif // _WIN32
        if(strcmp(argv[i], "-cfw") == 0)
        {
            global.CFWChildProcess = true;
            global.updateRulesetOnRequest = true;
        }
        else if(strcmp(argv[i], "-f") == 0 || strcmp(argv[i], "--file") == 0)
        {
            if(i < argc - 1)
                global.prefPath.assign(argv[++i]);
        }
        else if(strcmp(argv[i], "-g") == 0 || strcmp(argv[i], "--gen") == 0)
        {
            global.generatorMode = true;
        }
        else if(strcmp(argv[i], "--artifact") == 0)
        {
            if(i < argc - 1)
                global.generateProfiles.assign(argv[++i]);
        }
        else if(strcmp(argv[i], "-l") == 0 || strcmp(argv[i], "--log") == 0)
        {
            if(i < argc - 1)
                if(freopen(argv[++i], "a", stderr) == nullptr)
                    std::cerr<<"Error redirecting output to file.\n";
        }
    }
}

void signal_handler(int sig)
{
    //std::cerr<<"Interrupt signal "<<sig<<" received. Exiting gracefully...\n";
    writeLog(0, "Interrupt signal " + std::to_string(sig) + " received. Exiting gracefully...", LOG_LEVEL_FATAL);
    switch(sig)
    {
#ifndef _WIN32
    case SIGHUP:
    case SIGQUIT:
#endif // _WIN32
    case SIGTERM:
    case SIGINT:
        webServer.stop_web_server();
        break;
    }
}

void cron_tick_caller()
{
    if(global.enableCron)
        cron_tick();
}

int main(int argc, char *argv[])
{
#ifndef _DEBUG
    std::string prgpath = argv[0];
    setcd(prgpath); //first switch to program directory
#endif // _DEBUG
    if(fileExist("pref.toml"))
        global.prefPath = "pref.toml";
    else if(fileExist("pref.yml"))
        global.prefPath = "pref.yml";
    else if(!fileExist("pref.ini"))
    {
        if(fileExist("pref.example.toml"))
        {
            fileCopy("pref.example.toml", "pref.toml");
            global.prefPath = "pref.toml";
        }
        else if(fileExist("pref.example.yml"))
        {
            fileCopy("pref.example.yml", "pref.yml");
            global.prefPath = "pref.yml";
        }
        else if(fileExist("pref.example.ini"))
            fileCopy("pref.example.ini", "pref.ini");
    }
    chkArg(argc, argv);
    setcd(global.prefPath); //then switch to pref directory
    writeLog(0, "SubConverter " VERSION " starting up..", LOG_LEVEL_INFO);
#ifdef _WIN32
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(1, 1), &wsaData) != 0)
    {
        //std::cerr<<"WSAStartup failed.\n";
        writeLog(0, "WSAStartup failed.", LOG_LEVEL_FATAL);
        return 1;
    }
    UINT origcp = GetConsoleOutputCP();
    defer(SetConsoleOutputCP(origcp);)
    SetConsoleOutputCP(65001);
#else
    signal(SIGPIPE, SIG_IGN);
    signal(SIGABRT, SIG_IGN);
    signal(SIGHUP, signal_handler);
    signal(SIGQUIT, signal_handler);
    if(watched_parent_pid > 0)
        startParentWatchdog(watched_parent_pid);
#endif // _WIN32
    signal(SIGTERM, signal_handler);
    signal(SIGINT, signal_handler);

    SetConsoleTitle("SubConverter " VERSION);
    readConf();
    //vfs::vfs_read("vfs.ini");
    if(!global.updateRulesetOnRequest)
        refreshRulesets(global.customRulesets, global.rulesetsContent);

    std::string env_api_mode = getEnv("API_MODE"), env_managed_prefix = getEnv("MANAGED_PREFIX"), env_token = getEnv("API_TOKEN");
    global.APIMode = tribool().parse(toLower(env_api_mode)).get(global.APIMode);
    if(!env_managed_prefix.empty())
        global.managedConfigPrefix = env_managed_prefix;
    if(!env_token.empty())
        global.accessToken = env_token;

    if(global.generatorMode)
        return simpleGenerator();

    /*
    webServer.append_response("GET", "/", "text/plain", [](RESPONSE_CALLBACK_ARGS) -> std::string
    {
        return "subconverter " VERSION " backend\n";
    });
    */

    webServer.append_response("GET", "/version", "text/plain", [](RESPONSE_CALLBACK_ARGS) -> std::string
    {
        return "subconverter " VERSION " backend\n";
    });

    webServer.append_response("GET", "/refreshrules", "text/plain", [](RESPONSE_CALLBACK_ARGS) -> std::string
    {
        if(!global.accessToken.empty())
        {
            std::string token = getUrlArg(request.argument, "token");
            if(token != global.accessToken)
            {
                response.status_code = 403;
                return "Forbidden\n";
            }
        }
        refreshRulesets(global.customRulesets, global.rulesetsContent);
        return "done\n";
    });

    webServer.append_response("GET", "/readconf", "text/plain", [](RESPONSE_CALLBACK_ARGS) -> std::string
    {
        if(!global.accessToken.empty())
        {
            std::string token = getUrlArg(request.argument, "token");
            if(token != global.accessToken)
            {
                response.status_code = 403;
                return "Forbidden\n";
            }
        }
        readConf();
        if(!global.updateRulesetOnRequest)
            refreshRulesets(global.customRulesets, global.rulesetsContent);
        return "done\n";
    });

    webServer.append_response("POST", "/updateconf", "text/plain", [](RESPONSE_CALLBACK_ARGS) -> std::string
    {
        if(!global.accessToken.empty())
        {
            std::string token = getUrlArg(request.argument, "token");
            if(token != global.accessToken)
            {
                response.status_code = 403;
                return "Forbidden\n";
            }
        }
        std::string type = getUrlArg(request.argument, "type");
        if(type == "form" || type == "direct")
        {
            fileWrite(global.prefPath, request.postdata, true);
        }
        else
        {
            response.status_code = 501;
            return "Not Implemented\n";
        }

        readConf();
        if(!global.updateRulesetOnRequest)
            refreshRulesets(global.customRulesets, global.rulesetsContent);
        return "done\n";
    });

    webServer.append_response("GET", "/flushcache", "text/plain", [](RESPONSE_CALLBACK_ARGS) -> std::string
    {
        if(getUrlArg(request.argument, "token") != global.accessToken)
        {
            response.status_code = 403;
            return "Forbidden";
        }
        flushCache();
        return "done";
    });

    webServer.append_response("GET", "/sub", "text/plain;charset=utf-8", subconverter);

    webServer.append_response("HEAD", "/sub", "text/plain", subconverter);

    webServer.append_response("GET", "/sub2clashr", "text/plain;charset=utf-8", simpleToClashR);

    webServer.append_response("GET", "/surge2clash", "text/plain;charset=utf-8", surgeConfToClash);

    webServer.append_response("GET", "/getruleset", "text/plain;charset=utf-8", getRuleset);

    webServer.append_response("GET", "/getprofile", "text/plain;charset=utf-8", getProfile);

    webServer.append_response("GET", "/render", "text/plain;charset=utf-8", renderTemplate);

    if(!global.APIMode)
    {
        webServer.append_response("GET", "/get", "text/plain;charset=utf-8", [](RESPONSE_CALLBACK_ARGS) -> std::string
        {
            std::string url = urlDecode(getUrlArg(request.argument, "url"));
            return webGet(url, "");
        });

        webServer.append_response("GET", "/getlocal", "text/plain;charset=utf-8", [](RESPONSE_CALLBACK_ARGS) -> std::string
        {
            return fileGet(urlDecode(getUrlArg(request.argument, "path")));
        });
    }

    //webServer.append_response("POST", "/create-profile", "text/plain;charset=utf-8", createProfile);

    //webServer.append_response("GET", "/list-profiles", "text/plain;charset=utf-8", listProfiles);

    std::string env_port = getEnv("PORT");
    if(!env_port.empty())
        global.listenPort = to_int(env_port, global.listenPort);
    listener_args args = {global.listenAddress, global.listenPort, global.maxPendingConns, global.maxConcurThreads, cron_tick_caller, 200};
    //std::cout<<"Serving HTTP @ http://"<<listen_address<<":"<<listen_port<<std::endl;
    writeLog(0, "Startup completed. Serving HTTP @ http://" + global.listenAddress + ":" + std::to_string(global.listenPort), LOG_LEVEL_INFO);
    webServer.start_web_server_multi(&args);

#ifdef _WIN32
    WSACleanup();
#endif // _WIN32
    return 0;
}
