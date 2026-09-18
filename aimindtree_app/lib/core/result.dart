/// 统一结果类型（ARCHITECTURE §11 共享知识）。
///
/// 约定：**禁止裸 catch 吞错**。所有可能失败的操作返回 [Result]，由调用方显式处理；
/// 异步失败经 Riverpod `AsyncError` 在 UI 展示。
library;

/// 操作结果：要么 [Success] 要么 [Failure]。
sealed class Result<T> {
  const Result();
}

/// 成功，携带 [value]。
final class Success<T> extends Result<T> {
  const Success(this.value);
  final T value;
}

/// 失败，携带 [error] 与可选 [stackTrace]。
final class Failure<T> extends Result<T> {
  const Failure(this.error, [this.stackTrace]);
  final Object error;
  final StackTrace? stackTrace;

  String get message => error.toString();
}

/// [Result] 常用操作，避免调用方到处写 `switch` / `is` 判断。
extension ResultX<T> on Result<T> {
  bool get isSuccess => this is Success<T>;
  bool get isFailure => this is Failure<T>;

  /// 成功取值，失败返回 null。
  T? get valueOrNull => switch (this) {
        Success<T>(:final value) => value,
        Failure<T>() => null,
      };

  /// 成功取值，失败返回 [fallback]。
  T valueOr(T fallback) => valueOrNull ?? fallback;

  /// 分支消费，强制调用方同时处理两种情况。
  R fold<R>(
    R Function(T value) onSuccess,
    R Function(Object error, StackTrace? stack) onFailure,
  ) =>
      switch (this) {
        Success<T>(:final value) => onSuccess(value),
        Failure<T>(:final error, :final stackTrace) =>
          onFailure(error, stackTrace),
      };

  /// 成功后转换为新值；失败原样透传。
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Success<T>(:final value) => Success(transform(value)),
        Failure<T>(:final error, :final stackTrace) => Failure(error, stackTrace),
      };
}

/// 同步调用包装：把抛异常转为 [Failure]，杜绝 try/catch 散落。
Result<T> guard<T>(T Function() fn) {
  try {
    return Success(fn());
  } on Object catch (e, s) {
    return Failure(e, s);
  }
}

/// 异步调用包装：把抛异常 / Future 错误转为 [Failure]。
Future<Result<T>> guardAsync<T>(Future<T> Function() fn) async {
  try {
    return Success(await fn());
  } on Object catch (e, s) {
    return Failure(e, s);
  }
}
