<?php
header('Content-Type: application/json');

error_log('Current user: ' . exec('whoami'));
class Installer {
    public function sendError($message, $code = 400) {
        http_response_code($code);
        echo json_encode(['error' => $message]);
        exit;
    }

    private function sendSuccess() {
        header('Location: /install/');
    }

    public function downloadAndUnzip() {
        umask(0002); // Устанавливаем правильные права по умолчанию для новых файлов/папок
        // Параметры для первого zip-архива (setup.zip)
        $setupUrl = 'http://cloud.altcor.ru/setup/setup.zip';
        $setupZipPath = 'setup.zip';
        $setupExtractPath = __DIR__ . '/install/'; // Папка install в корневой директории

        // Параметры для второго zip-архива (api_install.zip)
        $apiUrl = 'http://cloud.altcor.ru/setup/api_install.zip';
        $apiZipPath = 'api_install.zip';
        $apiExtractPath = __DIR__ . '/install/api/'; // Папка install/api в корневой директории

        // Проверка и создание папки install
        if (!is_dir($setupExtractPath)) {
            if (!mkdir($setupExtractPath, 0775, true)) {
                $this->sendError('Ошибка создания папки: ' . $setupExtractPath);
            }
            if (!chmod($setupExtractPath, 0775)) {
                $this->sendError('Ошибка установки прав на папку: ' . $setupExtractPath);
            }
        }

        // Проверка прав на запись в папку install
        if (!is_writable($setupExtractPath)) {
            $this->sendError('Недостаточно прав у: ' . $setupExtractPath . '. Проверьте права доступа.');
        }

        // Проверка и создание папки install/api
        if (!is_dir($apiExtractPath)) {
            if (!mkdir($apiExtractPath, 0775, true)) {
                $this->sendError('Ошибка создания папки: ' . $apiExtractPath);
            }
            if (!chmod($apiExtractPath, 0775)) {
                $this->sendError('Ошибка установки прав на папку: ' . $apiExtractPath);
            }
        }

        // Проверка прав на запись в папку install/api
        if (!is_writable($apiExtractPath)) {
            $this->sendError('Недостаточно прав у: ' . $apiExtractPath . '. Проверьте права доступа.');
        }

        // Проверка свободного места для обеих папок
        $freeSpaceSetup = disk_free_space($setupExtractPath);
        if ($freeSpaceSetup === false || $freeSpaceSetup < 1024 * 1024) { // Меньше 1 МБ
            $this->sendError('Нет свободного места на диске ' . $setupExtractPath . '. Осталось места: ' . ($freeSpaceSetup !== false ? round($freeSpaceSetup / 1024 / 1024, 2) : 'unknown') . ' MB');
        }

        $freeSpaceApi = disk_free_space($apiExtractPath);
        if ($freeSpaceApi === false || $freeSpaceApi < 1024 * 1024) { // Меньше 1 МБ
            $this->sendError('Нет свободного места на диске ' . $apiExtractPath . '. Осталось места: ' . ($freeSpaceApi !== false ? round($freeSpaceApi / 1024 / 1024, 2) : 'unknown') . ' MB');
        }

        // Загрузка первого zip-файла (setup.zip)
        $setupZipContent = @file_get_contents($setupUrl);
        if ($setupZipContent === false) {
            $error = error_get_last();
            $this->sendError('Ошибка скачивания zip-архива ' . $setupUrl . '. Ошибка: ' . ($error['message'] ?? 'Неизвестная ошибка'));
        }

        // Сохранение первого zip-файла
        if (file_put_contents($setupZipPath, $setupZipContent) === false) {
            $error = error_get_last();
            $this->sendError('Ошибка сохранения ' . $setupZipPath . '. Ошибка: ' . ($error['message'] ?? 'Неизвестная ошибка'));
        }

        // Загрузка второго zip-файла (api_install.zip)
        $apiZipContent = @file_get_contents($apiUrl);
        if ($apiZipContent === false) {
            $error = error_get_last();
            $this->sendError('Ошибка скачивания zip-архива ' . $apiUrl . '. Ошибка: ' . ($error['message'] ?? 'Неизвестная ошибка'));
        }

        // Сохранение второго zip-файла
        if (file_put_contents($apiZipPath, $apiZipContent) === false) {
            $error = error_get_last();
            $this->sendError('Ошибка сохранения ' . $apiZipPath . '. Ошибка: ' . ($error['message'] ?? 'Неизвестная ошибка'));
        }

        // Проверка наличия расширения ZipArchive
        if (!class_exists('ZipArchive')) {
            $this->sendError('Нет модуля ZipArchive у PHP');
        }

        // Распаковка первого zip-файла (setup.zip)
        $zip = new ZipArchive;
        if ($zip->open($setupZipPath) === true) {
            if ($zip->extractTo($setupExtractPath)) {
                $zip->close();
                // Удаление временного zip-файла
                if (@unlink($setupZipPath) === false) {
                    $error = error_get_last();
                    $this->sendError('Ошибка удаления zip файла ' . $setupZipPath . '. Ошибка: ' . ($error['message'] ?? 'Неизвестная ошибка'));
                }
            } else {
                $zip->close();
                $this->sendError('Ошибка распаковки ' . $setupExtractPath);
            }
        } else {
            $this->sendError('Ошибка открытия zip-архива: ' . $setupZipPath);
        }

        // Распаковка второго zip-файла (api_install.zip)
        $zip = new ZipArchive;
        if ($zip->open($apiZipPath) === true) {
            if ($zip->extractTo($apiExtractPath)) {
                $zip->close();
                // Удаление временного zip-файла
                if (@unlink($apiZipPath) === false) {
                    $error = error_get_last();
                    $this->sendError('Ошибка удаления zip файла ' . $apiZipPath . '. Ошибка: ' . ($error['message'] ?? 'Неизвестная ошибка'));
                }
            } else {
                $zip->close();
                $this->sendError('Ошибка распаковки ' . $apiExtractPath);
            }
        } else {
            $this->sendError('Ошибка открытия zip-архива: ' . $apiZipPath);
        }

        $this->sendSuccess();
    }
}

$installer = new Installer();

try {
    if (is_dir(__DIR__ . '/install')) {
        header('Location: /install/');
        exit;
    }
    $installer->downloadAndUnzip();
} catch (Exception $e) {
    $installer->sendError('Ошибка: ' . $e->getMessage());
}
?>