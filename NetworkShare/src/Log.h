#pragma once
#include <cstring>
#include <string>
#include <utility>
#include <type_traits>
#include <system_error>

#ifdef WINDOWS
    #include <Windows.h>
    #undef max // windows macros
    #undef min // windows macros
    #define GetError() Logger::Error(GetLastError())
    using ColorType = WORD;
#elif defined(LINUX) || defined(MACOS)
    #include <cerrno>
    #include <unistd.h>
    #define GetError() Logger::Error(errno)
    using ColorType = const char* const;
#endif

#define Endl std::endl

namespace fmt
{
    template <typename... Args>
    inline std::string Format(const char* format, Args&&... args) noexcept
    {
        size_t size = (size_t)std::snprintf(NULL, 0, format, std::forward<Args>(args)...) + 1; // Extra space for '\0'
        std::string res(size, 0);
        std::snprintf(res.data(), size, format, std::forward<Args>(args)...);
        res.pop_back(); // '\0'
        return res;
    }

    template <typename... Args>
    inline std::string Format(const std::string& format, Args&&... args) noexcept
    {
        return Format(format.c_str(), std::forward<Args>(args)...);
    }

    struct Color
    {
        #ifdef WINDOWS
            static constexpr ColorType White = 0b0111;
            static constexpr ColorType LightRed = 0b1100;
            static constexpr ColorType LightGreen = 10;
        #elif defined(LINUX) || defined(MACOS)
            static inline ColorType White = "\033[0m";
            static inline ColorType LightRed = "\033[1;31m";
            static inline ColorType LightGreen = "\033[1;32m";
        #endif
    };
}

template <typename OutputStream>
struct Logger
{
public:
    static std::string Error(int error)
    {
        return "Error: " + std::to_string(error) + " (" + std::system_category().message(static_cast<int>(error)) + ")";
    }
private:
    OutputStream& m_Os;
    const char* const m_LogInfo;
    mutable bool m_NewLine = true;
    mutable bool m_IsColored = false;
    ColorType m_OutputColor;
private:
    inline const char* SetOutputColor(ColorType color) const noexcept
    {
        #ifdef WINDOWS
            if (m_IsColored)
                SetConsoleTextAttribute(GetStdHandle(STD_OUTPUT_HANDLE), color);
        #elif defined(LINUX) || defined(MACOS)
            if (m_IsColored && isatty(STDOUT_FILENO))
                return color;
        #endif
        return "";
    }
public:
    inline explicit Logger(const char* info, bool isColored, OutputStream& os, ColorType outcolor = fmt::Color::White) noexcept : m_Os(os), m_LogInfo(info), m_IsColored(isColored), m_OutputColor(outcolor) {}

    inline OutputStream& GetOStream() const noexcept { return m_Os; }

    // Warning: not thread safe use Print(), Println() or operator() for thread safety
    inline const Logger& operator<<(std::ostream& (*osmanip)(std::ostream&)) const noexcept
    {
        m_Os << *osmanip << SetOutputColor(fmt::Color::White);
        m_NewLine = true;
        return *this;
    }

    // Warning: not thread safe use Print(), Println() or operator() for thread safety
    template <class T>
    inline const Logger& operator<<(const T& msg) const noexcept
    {
        if (m_NewLine)
        {
            m_Os << SetOutputColor(m_OutputColor);
            m_Os << m_LogInfo;
            m_NewLine = false;
        }
        m_Os << msg;
        return *this;
    }

    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void Print(Args&&... args) const noexcept
    {
        #ifdef THREAD_SAFE_WRITER
            if constexpr (std::is_same_v<std::remove_cv_t<std::remove_reference_t<OutputStream>>, ThreadSafe::Writer>)
            {
                std::scoped_lock lock{ThreadSafe::LockedWriter::Mutex};
                m_Os.NativeStream() << SetOutputColor(m_OutputColor) << m_LogInfo;
                ((m_Os.NativeStream() << std::forward<Args>(args)), ...) << SetOutputColor(fmt::Color::White);
            }
            else
            {
                m_Os << SetOutputColor(m_OutputColor) << m_LogInfo;
                ((m_Os << std::forward<Args>(args)), ...) << SetOutputColor(fmt::Color::White);
            }
        #else
            m_Os << SetOutputColor(m_OutputColor) << m_LogInfo;
            ((m_Os << std::forward<Args>(args)), ...) << SetOutputColor(fmt::Color::White);
        #endif
    }

    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void Printf(const char* format, Args&&... args) const noexcept
    {
        #ifdef THREAD_SAFE_WRITER
            if constexpr (std::is_same_v<std::remove_cv_t<std::remove_reference_t<OutputStream>>, ThreadSafe::Writer>)
            {
                std::scoped_lock lock{ ThreadSafe::LockedWriter::Mutex };
                m_Os.NativeStream() << SetOutputColor(m_OutputColor) << m_LogInfo << fmt::Format(format, std::forward<Args>(args)...) << SetOutputColor(fmt::Color::White);
            }
            else
                m_Os << SetOutputColor(m_OutputColor) << m_LogInfo << fmt::Format(format, std::forward<Args>(args)...) << SetOutputColor(fmt::Color::White);
        #else
            m_Os << SetOutputColor(m_OutputColor) << m_LogInfo << fmt::Format(format, std::forward<Args>(args)...) << SetOutputColor(fmt::Color::White);
        #endif
    }

    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void Printfln(const char* format, Args&&... args) const
    {
        #ifdef THREAD_SAFE_WRITER
            if constexpr (std::is_same_v<std::remove_cv_t<std::remove_reference_t<OutputStream>>, ThreadSafe::Writer>)
            {
                std::scoped_lock lock{ ThreadSafe::LockedWriter::Mutex };
                m_Os.NativeStream() << SetOutputColor(m_OutputColor) << m_LogInfo << fmt::Format(format, std::forward<Args>(args)...) << SetOutputColor(fmt::Color::White) << '\n';
            }
            else
                m_Os << SetOutputColor(m_OutputColor) << m_LogInfo << fmt::Format(format, std::forward<Args>(args)...) << SetOutputColor(fmt::Color::White) << '\n';
        #else
            m_Os << SetOutputColor(m_OutputColor) << m_LogInfo << fmt::Format(format, std::forward<Args>(args)...) << SetOutputColor(fmt::Color::White) << '\n';
        #endif
    }

    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void Printf(const std::string& format, Args&&... args) const noexcept
    {
        Printf(format.c_str(), std::forward<Args>(args)...);
    }

    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void Printfln(const std::string& format, Args&&... args) const
    {
        Printfln(format.c_str(), std::forward<Args>(args)...);
    }

    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void Println(Args&&... args) const noexcept
    {
        Print(std::forward<Args>(args)..., '\n');
    }
    
    // Info: thread safe (if operator<<() is thread safe for custom types)
    template <typename... Args>
    inline void operator()(Args&&... args) const noexcept
    {
        Print(std::forward<Args>(args)...);
    }
};

template <typename OutputStream>
struct ToggledLogger
{
private:
    Logger<OutputStream> m_Logger;
    mutable bool m_On = false;
public:
    inline explicit ToggledLogger(const char* info, bool isColored, OutputStream& os, ColorType outcolor = fmt::Color::White) noexcept : m_Logger(info, isColored, os, outcolor) {}

    inline void SetOn() const noexcept { m_On = true;  }
    inline void SetOff() const noexcept { m_On = false; }

    inline const ToggledLogger& operator<<(std::ostream& (*osmanip)(std::ostream&)) const noexcept
    {
        if(m_On)
            m_Logger << *osmanip;
        return *this;
    }

    // Warning: not thread safe use Print(), Println() or operator() for thread safety
    template <class T>
    inline const ToggledLogger& operator<<(const T& msg) const noexcept
    {
        if(m_On)
            m_Logger << msg;
        return *this;
    }
};

inline const Logger Log("[INFO] ", false, std::cout);
inline const Logger Err("[ERROR] ", true, std::cerr, fmt::Color::LightRed);
inline const Logger Suc("[INFO] ", true, std::cout, fmt::Color::LightGreen);
inline const ToggledLogger Ver("[INFO] ", false, std::cout); // Verbose
