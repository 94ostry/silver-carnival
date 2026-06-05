package com.silvercarnival.processing;

import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/processing")
public class ProcessingController {

    @GetMapping("/health")
    public Map<String, String> health() {
        return Map.of("service", "processing-service", "status", "UP");
    }
}
