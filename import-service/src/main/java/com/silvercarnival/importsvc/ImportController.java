package com.silvercarnival.importsvc;

import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/import")
public class ImportController {

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("service", "import-service", "status", "UP");
    }
}
